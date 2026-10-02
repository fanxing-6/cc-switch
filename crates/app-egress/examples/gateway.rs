use anyhow::{Context, Result};
use cc_switch_app_egress::gateway::{Gateway, Upstream};
use serde::Deserialize;
use std::io::{self, Write};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Configuration {
    upstream: String,
    front_proxy: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let configuration: Configuration = if std::env::args().any(|argument| argument == "--stdin") {
        serde_json::from_reader(io::stdin())?
    } else {
        Configuration {
            upstream: std::env::var("CC_SWITCH_TEST_UPSTREAM").context("缺少测试代理地址")?,
            front_proxy: std::env::var("CC_SWITCH_TEST_FRONT_PROXY").ok(),
        }
    };
    let upstream = Upstream::parse(&configuration.upstream)?;
    let upstream = match configuration.front_proxy.filter(|value| !value.is_empty()) {
        Some(front) => upstream.with_front_proxy(Upstream::parse(&front)?)?,
        None => upstream,
    };
    let gateway = Gateway::start(upstream).await?;
    println!("{}", serde_json::to_string(&gateway.status())?);
    io::stdout().flush()?;
    tokio::signal::ctrl_c().await?;
    drop(gateway);
    Ok(())
}
