import base64
import concurrent.futures
import json
import pathlib
import subprocess
import time
import uuid
from urllib.parse import urlsplit


root = pathlib.Path(__file__).resolve().parents[2]
source = json.loads((root / "work/chain-native.json").read_text())
output = root / "work" / ("coexistence-validation-" + time.strftime("%Y%m%d-%H%M%S"))
output.mkdir(mode=0o700)
controller = "/Applications/CCSwitchNetworkProbe.app/Contents/MacOS/CCSwitchNetworkProbe"
client = "/Applications/CCSwitchPathProbe.app/Contents/MacOS/CCSwitchEgressProbe"
settings = {**source, "applicationPaths": ["/Applications/CCSwitchPathProbe.app"], "loopbackPorts": [15721]}
results = []


def control(operation, configuration=None):
    completed = subprocess.run([controller, operation], input=json.dumps(configuration) if configuration else None,
                               capture_output=True, text=True, timeout=30)
    if completed.returncode:
        raise RuntimeError(completed.stdout)
    return json.loads(completed.stdout)


def external_health():
    completed = subprocess.run(["/usr/bin/curl", "--noproxy", "*", "-fsS", "--max-time", "12",
                                "https://www.cloudflare.com/cdn-cgi/trace"], capture_output=True, timeout=15)
    return completed.returncode == 0 and b"ip=" in completed.stdout


def request(name, url, expected):
    path = output / (name + ".json")
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        health = executor.submit(external_health)
        process = subprocess.Popen([client, str(path), url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            process.wait(timeout=18)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            result = {"connected": False, "timed_out": True}
        else:
            result = json.loads(path.read_text())
        passed = result["connected"] == expected
        if expected:
            passed = passed and f"ip={urlsplit(source['upstream']).hostname}\n" in base64.b64decode(result["response_base64"]).decode()
        result.update(name=name, passed=passed, unprotected_network_healthy=health.result())
        results.append(result)
        (output / "results.json").write_text(json.dumps(results, indent=2))
        print(json.dumps({key: result[key] for key in ["name", "passed", "unprotected_network_healthy"]}), flush=True)
        if not result["unprotected_network_healthy"]:
            raise RuntimeError("其他应用的联网检查失败，停止测试并移除测试配置")


state = control("application-status")
assert all(path in ["/Applications/CCSwitchPathProbe.app", "/Applications/CCSwitchEgressProbe.app"]
           for path in state["applicationPaths"])
try:
    control("protect-applications", settings)
    request("protected-exit", "https://www.cloudflare.com/cdn-cgi/trace", True)
    control("protect-applications", {**settings, "frontProxy": "http://127.0.0.1:58997"})
    request("front-unavailable", "http://1.1.1.1/cdn-cgi/trace", False)
    control("stop-transparent")
    request("proxy-stopped", "http://1.1.1.1/cdn-cgi/trace", False)
    request("dns-stopped", "resolve://ccswitch-" + uuid.uuid4().hex + ".1.1.1.1.sslip.io", False)
finally:
    control("disable-protection")
print(str(output), flush=True)
raise SystemExit(0 if all(item["passed"] and item["unprotected_network_healthy"] for item in results) else 1)
