use anyhow::{ensure, Context, Result};
use std::{path::Path, process::{Child, Command, Stdio}};

pub const PROFILE: &str = r#"(version 1)
(allow default)
(deny network*)
(allow network-outbound (remote tcp (param "PROXY_ENDPOINT")))
(allow network-bind network-inbound network-outbound (subpath (param "IPC_DIRECTORY")))
(deny mach-lookup (global-name "com.apple.nsurlsessiond"))
(deny mach-lookup (global-name "com.apple.nsurlsessiond.private"))
"#;

pub fn command(executable: &Path, port: u16, ipc_directory: &Path) -> Result<Command> {
    ensure!(cfg!(target_os = "macos"), "受保护启动仅支持 macOS");
    ensure!(Path::new("/usr/bin/sandbox-exec").is_file(), "当前 macOS 缺少 sandbox-exec，启动已停止");
    ensure!(port != 0, "代理端口无效");
    ensure!(ipc_directory.is_dir(), "IPC 目录不存在");
    let ipc = ipc_directory.canonicalize()?;
    ensure!(ipc.to_str().is_some(), "IPC 目录需要有效的 UTF-8 路径");
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command.arg("-D").arg(format!("PROXY_ENDPOINT=localhost:{port}"))
        .arg("-D").arg(format!("IPC_DIRECTORY={}", ipc.display()))
        .arg("-p").arg(PROFILE).arg(executable);
    let proxy = format!("http://127.0.0.1:{port}");
    for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { command.env(name, &proxy); }
    for name in ["NO_PROXY", "no_proxy"] { command.env(name, ""); }
    command.env("NODE_USE_ENV_PROXY", "1");
    command.env_remove("ELECTRON_RUN_AS_NODE");
    command.stdin(Stdio::null());
    Ok(command)
}

pub fn spawn_probe(executable: &Path, args: &[String], port: u16, ipc_directory: &Path) -> Result<Child> {
    command(executable, port, ipc_directory)?.args(args).spawn().context("无法启动受限制进程")
}
