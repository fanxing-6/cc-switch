import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@/components/ui/button";

interface EgressStatus {
  unsupported?: boolean;
  installed: boolean;
  proxyConnected: boolean;
  filterEnabled: boolean;
  applicationPaths: string[];
  testApplicationOnly: boolean;
  frontProxy?: string;
}

export function AppEgressSettings() {
  const [status, setStatus] = useState<EgressStatus>();
  const [paths, setPaths] = useState(["/Applications/ChatGPT.app"]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [frontProxy, setFrontProxy] = useState("");
  const initialized = useRef(false);

  async function refresh() {
    const value = await invoke<EgressStatus>("app_egress_status");
    setStatus(value);
    if (!initialized.current) {
      setFrontProxy(value.frontProxy ?? "");
      if (value.applicationPaths?.length) {
        setPaths(value.applicationPaths.filter((path) =>
          ["/Applications/ChatGPT.app", "/Applications/Codex.app"].includes(path)));
      }
      initialized.current = true;
    }
  }

  useEffect(() => {
    const read = () => refresh().catch((error) => setError(String(error)));
    void read();
    const interval = window.setInterval(read, 10000);
    return () => window.clearInterval(interval);
  }, []);

  async function run(command: string) {
    setBusy(true);
    setError("");
    try {
      await invoke(command, command === "app_egress_enable" ? { paths, frontProxy } : {});
      await refresh();
    } catch (error) {
      setError(String(error));
    } finally {
      setBusy(false);
    }
  }

  if (status?.unsupported) return null;
  const active = status?.filterEnabled && status.proxyConnected && !status.testApplicationOnly;
  return (
    <section className="space-y-3 border-t pt-4">
      <h4 className="font-semibold">ChatGPT / Codex 应用连接保护</h4>
      <p className="text-sm text-muted-foreground">
        使用已保存的全局出站代理，接管所选应用及应用内部进程。
        CC Switch 的出站连接同时受到保护。应用可以正常退出、重新启动和更新。
        代理不可用时阻断连接；DNS 通过代理发送。HTTP、HTTPS、SOCKS5h 上游需要固定 IP。
      </p>
      <label className="block space-y-2 text-sm">
        <span>前置代理（可选）</span>
        <input type="password" autoComplete="off" spellCheck={false}
          className="w-full rounded-md border bg-background px-3 py-2"
          placeholder="socks5h://127.0.0.1:7891 或 http://127.0.0.1:7890"
          value={frontProxy} disabled={busy}
          onChange={(event) => setFrontProxy(event.target.value.trim())} />
      </label>
      <p className="text-sm text-muted-foreground">
        填写后，应用连接依次经过前置代理、全局出站代理中的最终节点。
        前置代理支持 HTTP、HTTPS、SOCKS5h，地址使用固定 IP。
        任意一段连接失败都会停止请求。留空表示直接连接最终节点。
      </p>
      <p className="text-sm text-muted-foreground">
        普通 UDP 当前被阻断，语音功能可能受影响。安装需要 macOS 网络扩展授权；
        免费个人构建目前仅在 SIP 已关闭的机器完成验证。首次启用后请重新启动受保护应用。
      </p>
      <p className="text-sm" role="status">
        {active ? "系统代理已连接，连接保护开关已启用" : status?.testApplicationOnly && status.filterEnabled
          ? "当前仅保护验证程序" : status?.filterEnabled
            ? "连接保护已启用，代理尚未连接" : "应用连接保护尚未启用"}
      </p>
      {["/Applications/ChatGPT.app", "/Applications/Codex.app"].map((path) => (
        <label key={path} className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={paths.includes(path)} disabled={busy}
            onChange={(event) => setPaths(event.target.checked
              ? [...paths, path] : paths.filter((item) => item !== path))} />
          {path}
        </label>
      ))}
      {status?.applicationPaths?.length ? (
        <p className="text-xs text-muted-foreground">已保护：{status.applicationPaths.join("、")}</p>
      ) : null}
      <div className="flex flex-wrap gap-2">
        <Button variant="outline" disabled={busy} onClick={() => void run("app_egress_install")}>
          安装 / 更新网络扩展
        </Button>
        <Button disabled={busy || !status?.installed || paths.length === 0}
          onClick={() => void run("app_egress_enable")}>启用应用保护</Button>
        <Button variant="outline" disabled={busy || !status?.filterEnabled}
          onClick={() => void run("app_egress_disable")}>关闭应用保护</Button>
      </div>
      {error && <p className="text-sm text-destructive" role="alert">{error}</p>}
    </section>
  );
}
