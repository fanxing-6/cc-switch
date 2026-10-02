use crate::gateway::{Gateway, Upstream};
use serde::Deserialize;
use std::ffi::{c_char, CStr};
use tokio::runtime::Runtime;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Configuration {
    upstream: String,
    front_proxy: Option<String>,
}

struct NativeGateway {
    gateway: Gateway,
    runtime: Runtime,
}

fn start(configuration: &str) -> anyhow::Result<NativeGateway> {
    let configuration: Configuration = serde_json::from_str(configuration)?;
    let upstream = Upstream::parse(&configuration.upstream)?;
    let upstream = match configuration.front_proxy.filter(|value| !value.is_empty()) {
        Some(front) => upstream.with_front_proxy(Upstream::parse(&front)?)?,
        None => upstream,
    };
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()?;
    let gateway = runtime.block_on(Gateway::start(upstream))?;
    Ok(NativeGateway { gateway, runtime })
}

#[no_mangle]
pub unsafe extern "C" fn ccs_gateway_start(configuration: *const c_char, port: *mut u16) -> *mut std::ffi::c_void {
    if configuration.is_null() || port.is_null() { return std::ptr::null_mut(); }
    let Ok(configuration) = CStr::from_ptr(configuration).to_str() else { return std::ptr::null_mut(); };
    let Ok(gateway) = start(configuration) else { return std::ptr::null_mut(); };
    *port = gateway.gateway.address.port();
    Box::into_raw(Box::new(gateway)).cast()
}

#[no_mangle]
pub unsafe extern "C" fn ccs_gateway_stop(gateway: *mut std::ffi::c_void) {
    if gateway.is_null() { return; }
    let NativeGateway { gateway, runtime } = *Box::from_raw(gateway.cast::<NativeGateway>());
    drop(gateway);
    runtime.shutdown_timeout(std::time::Duration::from_secs(2));
}
