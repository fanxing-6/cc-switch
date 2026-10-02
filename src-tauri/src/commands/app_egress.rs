use serde_json::{json, Value};

#[cfg(target_os = "macos")]
mod native {
    use super::*;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use tauri::Manager;

    pub const HELPER: &str = "/Applications/CCSwitchNetworkProbe.app/Contents/MacOS/CCSwitchNetworkProbe";

    pub fn control(operation: &str, input: Option<&Value>) -> Result<Value, String> {
        let mut child = Command::new(HELPER)
            .arg(operation)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("无法启动网络扩展控制程序: {error}"))?;
        if let Some(input) = input {
            let data = serde_json::to_vec(input).map_err(|error| error.to_string())?;
            child.stdin.take().ok_or("无法打开配置通道")?
                .write_all(&data).map_err(|error| error.to_string())?;
        } else {
            drop(child.stdin.take());
        }
        let output = child.wait_with_output().map_err(|error| error.to_string())?;
        let value = serde_json::Deserializer::from_slice(&output.stdout).into_iter::<Value>()
            .last().ok_or("网络扩展没有返回状态")?.map_err(|error| error.to_string())?;
        if !output.status.success() {
            return Err(value["message"].as_str().unwrap_or("网络扩展操作失败").to_string());
        }
        Ok(value)
    }

    pub fn status() -> Result<Value, String> {
        if !Path::new(HELPER).is_file() {
            return Ok(json!({"installed": false, "proxyConnected": false,
                "filterEnabled": false, "applicationPaths": [], "testApplicationOnly": true}));
        }
        control("application-status", None)
    }

    pub fn own_bundle() -> Result<PathBuf, String> {
        let executable = std::env::current_exe().map_err(|error| error.to_string())?;
        executable.ancestors().find(|path| path.extension().is_some_and(|value| value == "app"))
            .map(Path::to_path_buf).ok_or("请从已安装的 CC Switch.app 启用应用保护".to_string())
    }

    pub fn install(app: tauri::AppHandle) -> Result<Value, String> {
        let source = app.path().resource_dir().map_err(|error| error.to_string())?
            .join("CCSwitchNetworkProbe.app");
        if !source.is_dir() { return Err("安装包中缺少网络扩展组件".to_string()); }
        let verification = Command::new("/usr/bin/codesign")
            .args(["--verify", "--deep", "--strict"]).arg(&source).status()
            .map_err(|error| error.to_string())?;
        if !verification.success() { return Err("网络扩展签名校验失败".to_string()); }
        let destination = Path::new("/Applications/CCSwitchNetworkProbe.app");
        if destination.exists() {
            let backup = app.path().app_local_data_dir().map_err(|error| error.to_string())?
                .join("network-extension-backups")
                .join(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
                    .map_err(|error| error.to_string())?.as_nanos().to_string());
            std::fs::create_dir_all(&backup).map_err(|error| error.to_string())?;
            std::fs::rename(destination, backup.join("CCSwitchNetworkProbe.app"))
                .map_err(|error| format!("无法保存网络扩展备份: {error}"))?;
        }
        let copied = Command::new("/usr/bin/ditto").arg(source).arg(destination).status()
            .map_err(|error| error.to_string())?;
        if !copied.success() { return Err("无法安装网络扩展，请检查 Applications 文件夹权限".to_string()); }
        control("activate", None)?;
        control("refresh-filter", None)
    }

    pub fn protect(mut paths: Vec<String>, upstream: String, front_proxy: String, loopback_port: u16) -> Result<Value, String> {
        if upstream.trim().is_empty() { return Err("请填写并保存全局出站代理地址".to_string()); }
        let applications = ["/Applications/ChatGPT.app", "/Applications/Codex.app"];
        if paths.is_empty() || paths.iter().any(|path| !applications.contains(&path.as_str())) {
            return Err("请选择已安装的 ChatGPT 或 Codex 应用".to_string());
        }
        paths.push(own_bundle()?.to_string_lossy().into_owned());
        control("protect-applications", Some(&json!({
            "probeMode": "proxy", "upstream": upstream, "applicationPaths": paths,
            "frontProxy": front_proxy,
            "loopbackPorts": [loopback_port]
        })))
    }

    pub fn update_upstream(url: &str) -> Result<(), String> {
        let status = status()?;
        let paths = status["applicationPaths"].as_array().ok_or("应用保护状态格式无效")?;
        if paths.is_empty() { return Ok(()); }
        if url.trim().is_empty() { return Err("应用保护启用期间需要保留代理地址".to_string()); }
        control("protect-applications", Some(&json!({
            "probeMode": "proxy", "upstream": url, "applicationPaths": paths,
            "loopbackPorts": status["loopbackPorts"]
        })))?;
        Ok(())
    }
}

pub fn update_application_upstream(url: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    native::update_upstream(url)?;
    #[cfg(not(target_os = "macos"))]
    let _ = url;
    Ok(())
}

#[tauri::command]
pub async fn app_egress_status(state: tauri::State<'_, crate::store::AppState>) -> Result<Value, String> {
    #[cfg(target_os = "macos")]
    {
        let mut status = tokio::task::spawn_blocking(native::status).await.map_err(|error| error.to_string())??;
        status["frontProxy"] = json!(state.db.get_setting("app_egress_front_proxy")
            .map_err(|error| error.to_string())?.unwrap_or_default());
        return Ok(status);
    }
    #[cfg(not(target_os = "macos"))]
    Ok(json!({"unsupported": true}))
}

#[tauri::command]
pub async fn app_egress_install(app: tauri::AppHandle) -> Result<Value, String> {
    #[cfg(target_os = "macos")]
    return tokio::task::spawn_blocking(move || native::install(app)).await.map_err(|error| error.to_string())?;
    #[cfg(not(target_os = "macos"))]
    { let _ = app; Err("应用保护需要 macOS".to_string()) }
}

#[tauri::command]
pub async fn app_egress_enable(state: tauri::State<'_, crate::store::AppState>, paths: Vec<String>, front_proxy: String) -> Result<Value, String> {
    let upstream = state.db.get_global_proxy_url().map_err(|error| error.to_string())?
        .ok_or("请填写并保存全局出站代理地址")?;
    let loopback_port = state.proxy_service.get_config().await?.listen_port;
    #[cfg(target_os = "macos")]
    {
        let front = front_proxy.clone();
        let status = tokio::task::spawn_blocking(move || native::protect(paths, upstream, front, loopback_port))
            .await.map_err(|error| error.to_string())??;
        state.db.set_setting("app_egress_front_proxy", &front_proxy).map_err(|error| error.to_string())?;
        return Ok(status);
    }
    #[cfg(not(target_os = "macos"))]
    { let _ = (paths, upstream, front_proxy, loopback_port); Err("应用保护需要 macOS".to_string()) }
}

#[tauri::command]
pub async fn app_egress_disable() -> Result<Value, String> {
    #[cfg(target_os = "macos")]
    return tokio::task::spawn_blocking(|| native::control("disable-protection", None)).await.map_err(|error| error.to_string())?;
    #[cfg(not(target_os = "macos"))]
    Err("应用保护需要 macOS".to_string())
}
