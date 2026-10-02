use anyhow::{ensure, Context, Result};
use axum::{body::Body, extract::State, handler::Handler, http::{Request, Response, StatusCode}};
use fast_socks5::client::{Config, Socks5Stream};
use fast_socks5::{AuthenticationMethod, Socks5Command, util::target_addr::ToTargetAddr};
use hyper_util::rt::TokioIo;
use percent_encoding::percent_decode_str;
use serde::Serialize;
use std::{net::{IpAddr, Ipv4Addr, SocketAddr}, sync::{Arc, atomic::{AtomicU64, Ordering}}, time::Duration};
use tokio::{io::{AsyncRead, AsyncWrite}, net::{TcpListener, TcpStream}, sync::watch, task::JoinHandle};
use tokio_rustls::{rustls::{self, pki_types::ServerName}, TlsConnector};
use url::{Host, Url};

trait Tunnel: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Tunnel for T {}
type Connection = Box<dyn Tunnel>;

#[derive(Clone)]
pub struct Upstream {
    url: Url,
    address: SocketAddr,
    username: String,
    password: String,
    front_proxy: Option<Box<Upstream>>,
}

impl Upstream {
    pub fn parse(value: &str) -> Result<Self> {
        let mut url = Url::parse(value).context("代理 URL 格式无效")?;
        ensure!(matches!(url.scheme(), "http" | "https" | "socks5h"), "受保护启动支持 http、https、socks5h 代理；SOCKS 请使用 socks5h 以远程解析目标域名");
        ensure!(url.path() == "/" || url.path().is_empty(), "代理 URL 不允许包含路径");
        ensure!(url.query().is_none() && url.fragment().is_none(), "代理 URL 不允许包含参数");
        let address = match url.host().context("代理地址为空")? {
            Host::Ipv4(ip) => IpAddr::V4(ip),
            Host::Ipv6(ip) => IpAddr::V6(ip),
            Host::Domain("localhost") => IpAddr::V4(Ipv4Addr::LOCALHOST),
            Host::Domain(host) => host.parse::<IpAddr>().context("代理服务器请填写固定 IP，以免连接代理时产生系统 DNS 查询")?,
        };
        ensure!(!address.is_unspecified() && !address.is_multicast(), "代理必须使用有效的单播 IP");
        url.set_ip_host(address).map_err(|_| anyhow::anyhow!("代理 IP 无效"))?;
        let port = url.port_or_known_default().context("请填写代理端口")?;
        ensure!(port != 0, "代理端口必须大于零");
        let username = percent_decode_str(url.username()).decode_utf8()?.into_owned();
        let password = percent_decode_str(url.password().unwrap_or_default()).decode_utf8()?.into_owned();
        ensure!(!username.is_empty() || password.is_empty(), "代理密码需要对应的用户名");
        Ok(Self { url, address: SocketAddr::new(address, port), username, password, front_proxy: None })
    }

    pub fn with_front_proxy(mut self, front_proxy: Upstream) -> Result<Self> {
        ensure!(self.address != front_proxy.address, "前置代理与最终代理地址不能相同");
        ensure!(front_proxy.front_proxy.is_none(), "前置代理配置不能嵌套");
        self.front_proxy = Some(Box::new(front_proxy));
        Ok(self)
    }

    pub fn display(&self) -> String {
        let destination = format!("{}://{}", self.url.scheme(), self.address);
        match &self.front_proxy {
            Some(front) => format!("{} -> {destination}", front.display()),
            None => destination,
        }
    }

    async fn tunnel(&self, host: &str, port: u16) -> Result<Connection> {
        let stream: Connection = match &self.front_proxy {
            Some(front) => {
                let socket = Box::new(TcpStream::connect(front.address).await?);
                front.proxy_tunnel(socket, &self.address.ip().to_string(), self.address.port()).await?
            }
            None => Box::new(TcpStream::connect(self.address).await?),
        };
        // 应用已经使用最终代理时，保留应用发出的认证与 CONNECT 请求。
        if host.parse::<IpAddr>().ok() == Some(self.address.ip()) && port == self.address.port() {
            return Ok(stream);
        }
        self.proxy_tunnel(stream, host, port).await
    }

    async fn proxy_tunnel(&self, socket: Connection, host: &str, port: u16) -> Result<Connection> {
        if self.url.scheme() == "socks5h" {
            let authentication = (!self.username.is_empty()).then(|| AuthenticationMethod::Password {
                username: self.username.clone(), password: self.password.clone(),
            });
            let mut stream = Socks5Stream::use_stream(socket, authentication, Config::default()).await?;
            stream.request(Socks5Command::TCPConnect, (host, port).to_target_addr()?).await?;
            return Ok(Box::new(stream));
        }
        let mut stream: Connection = if self.url.scheme() == "https" {
            let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()?.with_root_certificates(roots).with_no_client_auth();
            let name = ServerName::IpAddress(self.address.ip().into());
            Box::new(TlsConnector::from(Arc::new(config)).connect(name, socket).await?)
        } else {
            socket
        };
        if self.username.is_empty() {
            async_http_proxy::http_connect_tokio(&mut stream, host, port).await?;
        } else {
            async_http_proxy::http_connect_tokio_with_basic_auth(&mut stream, host, port, &self.username, &self.password).await?;
        }
        Ok(stream)
    }
}

struct GatewayState {
    upstream: Upstream,
    requests: AtomicU64,
    failures: AtomicU64,
    stop: watch::Receiver<bool>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStatus {
    pub address: String,
    pub upstream: String,
    pub requests: u64,
    pub failures: u64,
    pub listening: bool,
}

pub struct Gateway {
    pub address: SocketAddr,
    state: Arc<GatewayState>,
    stop: watch::Sender<bool>,
    task: JoinHandle<std::io::Result<()>>,
}

impl Gateway {
    pub async fn start(upstream: Upstream) -> Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let address = listener.local_addr()?;
        ensure!(address != upstream.address, "代理地址产生循环");
        let (stop, receiver) = watch::channel(false);
        let state = Arc::new(GatewayState { upstream, requests: AtomicU64::new(0), failures: AtomicU64::new(0), stop: receiver });
        let service = handle.with_state(state.clone()).into_make_service();
        let mut stopped = stop.subscribe();
        let task = tokio::spawn(async move {
            axum::serve(listener, service).with_graceful_shutdown(async move { let _ = stopped.changed().await; }).await
        });
        Ok(Self { address, state, stop, task })
    }

    pub fn status(&self) -> GatewayStatus {
        GatewayStatus { address: self.address.to_string(), upstream: self.state.upstream.display(), requests: self.state.requests.load(Ordering::Relaxed), failures: self.state.failures.load(Ordering::Relaxed), listening: !self.task.is_finished() }
    }
}

impl Drop for Gateway {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
        self.task.abort();
    }
}

async fn handle(State(state): State<Arc<GatewayState>>, mut request: Request<Body>) -> Response<Body> {
    state.requests.fetch_add(1, Ordering::Relaxed);
    if request.method() == axum::http::Method::CONNECT {
        let Some(authority) = request.uri().authority() else { return failure(&state, StatusCode::BAD_REQUEST); };
        let Some(port) = authority.port_u16() else { return failure(&state, StatusCode::BAD_REQUEST); };
        let host = authority.host().trim_start_matches('[').trim_end_matches(']');
        let mut tunnel = match tokio::time::timeout(Duration::from_secs(15), state.upstream.tunnel(host, port)).await {
            Ok(Ok(stream)) => stream,
            _ => return failure(&state, StatusCode::BAD_GATEWAY),
        };
        let upgraded = hyper::upgrade::on(&mut request);
        tokio::spawn(async move {
            let mut stopped = state.stop.clone();
            let transfer = async {
                let client = upgraded.await?;
                tokio::io::copy_bidirectional(&mut TokioIo::new(client), &mut tunnel).await?;
                Ok::<_, anyhow::Error>(())
            };
            tokio::select! {
                result = transfer => { if result.is_err() { state.failures.fetch_add(1, Ordering::Relaxed); } }
                _ = stopped.changed() => {}
            }
        });
        return Response::new(Body::empty());
    }
    // HTTP 与 CONNECT 使用相同的代理链，目标域名交给最终代理。
    if request.uri().scheme_str() != Some("http") || request.headers().contains_key("upgrade") {
        return failure(&state, StatusCode::BAD_REQUEST);
    }
    let Some(authority) = request.uri().authority().cloned() else {
        return failure(&state, StatusCode::BAD_REQUEST);
    };
    let host = authority.host().trim_start_matches('[').trim_end_matches(']');
    let port = authority.port_u16().unwrap_or(80);
    let stream = match tokio::time::timeout(Duration::from_secs(15), state.upstream.tunnel(host, port)).await {
        Ok(Ok(stream)) => stream,
        _ => return failure(&state, StatusCode::BAD_GATEWAY),
    };
    let (mut sender, connection) = match hyper::client::conn::http1::handshake(TokioIo::new(stream)).await {
        Ok(connection) => connection,
        Err(_) => return failure(&state, StatusCode::BAD_GATEWAY),
    };
    let mut connection_stop = state.stop.clone();
    tokio::spawn(async move {
        tokio::select! { _ = connection => {}, _ = connection_stop.changed() => {} }
    });
    let target = request.uri().path_and_query().map(|value| value.as_str()).unwrap_or("/");
    *request.uri_mut() = match target.parse() {
        Ok(uri) => uri,
        Err(_) => return failure(&state, StatusCode::BAD_REQUEST),
    };
    remove_hop_headers(request.headers_mut());
    let mut stopped = state.stop.clone();
    let response = tokio::select! {
        response = sender.send_request(request) => response,
        _ = stopped.changed() => return failure(&state, StatusCode::SERVICE_UNAVAILABLE),
    };
    match response {
        Ok(mut response) => {
            remove_hop_headers(response.headers_mut());
            response.map(Body::new)
        }
        Err(_) => failure(&state, StatusCode::BAD_GATEWAY),
    }
}

fn remove_hop_headers(headers: &mut axum::http::HeaderMap) {
    let connection = headers.get("connection").and_then(|v| v.to_str().ok()).unwrap_or_default().to_owned();
    for name in connection.split(',') { headers.remove(name.trim()); }
    for name in ["connection", "proxy-connection", "proxy-authorization", "proxy-authenticate", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade"] { headers.remove(name); }
}

fn failure(state: &GatewayState, code: StatusCode) -> Response<Body> {
    state.failures.fetch_add(1, Ordering::Relaxed);
    let mut response = Response::new(Body::from("App egress proxy request failed"));
    *response.status_mut() = code;
    response
}
