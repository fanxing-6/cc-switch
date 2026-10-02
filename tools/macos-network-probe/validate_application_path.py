import base64
import json
import os
import pathlib
import subprocess
import time
import uuid
from urllib.parse import urlsplit


root = pathlib.Path(__file__).resolve().parents[2]
source = json.loads((root / "work/chain-native.json").read_text())
output = root / "work" / ("application-validation-" + time.strftime("%Y%m%d-%H%M%S"))
output.mkdir()
os.umask(0o077)
controller = "/Applications/CCSwitchNetworkProbe.app/Contents/MacOS/CCSwitchNetworkProbe"
client = "/Applications/CCSwitchPathProbe.app/Contents/MacOS/CCSwitchEgressProbe"
settings = {**source, "applicationPaths": ["/Applications/CCSwitchPathProbe.app"], "loopbackPorts": [15721]}
results = []


def control(operation, configuration=None):
    completed = subprocess.run([controller, operation], input=json.dumps(configuration) if configuration else None,
                               capture_output=True, text=True, timeout=30)
    if completed.returncode != 0:
        raise RuntimeError(completed.stdout)
    return json.loads(completed.stdout)


def request(name, url, expected):
    path = output / (name + ".json")
    process = subprocess.Popen([client, str(path), url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        process.wait(timeout=18)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        result = {"connected": False, "timed_out": True, "pid": process.pid, "url": url}
    else:
        result = json.loads(path.read_text())
    passed = result["connected"] == expected
    if expected and "cdn-cgi/trace" in url and result["connected"]:
        passed = passed and f"ip={urlsplit(source['upstream']).hostname}\n" in base64.b64decode(result["response_base64"]).decode()
    if expected and url.startswith("resolve:"):
        passed = passed and result.get("addresses") == ["1.1.1.1"]
    if not expected and result.get("error_code") in [-1022, -1200, -1202]:
        passed = False
    result.update(name=name, passed=passed)
    results.append(result)
    (output / "results.json").write_text(json.dumps(results, indent=2))
    print(json.dumps({"name": name, "passed": passed, "connected": result["connected"]}), flush=True)


def resolution_url():
    return "resolve://ccswitch-" + uuid.uuid4().hex + ".1.1.1.1.sslip.io"


control("protect-applications", {**settings, "applicationPaths": ["/Applications/CCSwitchEgressProbe.app"]})
control("protect-applications", settings)
state = control("application-status")
assert state["applicationPaths"] == settings["applicationPaths"] and state["proxyConnected"] and state["filterEnabled"]
request("application-exit", "https://www.cloudflare.com/cdn-cgi/trace", True)
request("application-system-dns", resolution_url(), True)
request("application-local-api", "http://127.0.0.1:15721/health", True)
subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(root / "work/swift-module-cache"),
                str(root / "tools/macos-network-probe/Client.swift"),
                str(root / "tools/macos-network-probe/Upstream.swift"), "-o", str(output / "updated-client")],
               check=True, capture_output=True, timeout=60,
               env={**os.environ, "TMPDIR": str(root / "work/per-app-vpn-probe/compiler")})
subprocess.run(["cp", str(output / "updated-client"), client], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", "/Applications/CCSwitchPathProbe.app"],
               check=True, capture_output=True)
request("updated-application-exit", "https://www.cloudflare.com/cdn-cgi/trace", True)
control("stop-transparent")
request("stopped-application-ipv4", "http://1.1.1.1/cdn-cgi/trace", False)
request("stopped-application-system-dns", resolution_url(), False)
control("protect-applications", settings)
control("crash-test")
time.sleep(6)
request("terminated-provider-ipv4", "http://1.1.1.1/cdn-cgi/trace", False)
request("terminated-provider-system-dns", resolution_url(), False)
control("protect-applications", settings)
request("restarted-provider-exit", "https://www.cloudflare.com/cdn-cgi/trace", True)
control("stop-transparent")
subprocess.run(["curl", "--noproxy", "*", "-fsS", "--max-time", "5", "http://127.0.0.1:15721/health"],
               check=True, capture_output=True, timeout=7)
print(str(output), flush=True)
raise SystemExit(0 if all(item["passed"] for item in results) else 1)
