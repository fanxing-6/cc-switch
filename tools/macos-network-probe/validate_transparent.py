import base64
import json
import os
import pathlib
import subprocess
import time
import uuid
from urllib.parse import urlsplit

import dns.message
import dns.rcode


root = pathlib.Path(__file__).resolve().parents[2]
source = json.loads((root / "work/chain-native.json").read_text())
output = root / "work" / ("transparent-validation-" + time.strftime("%Y%m%d-%H%M%S"))
output.mkdir()
os.umask(0o077)
controller = "/Applications/CCSwitchNetworkProbe.app/Contents/MacOS/CCSwitchNetworkProbe"
client = "/Applications/CCSwitchEgressProbe.app/Contents/MacOS/CCSwitchEgressProbe"
query = dns.message.make_query("example.com", "A")
query_path = output / "query.bin"
query_path.write_bytes(query.to_wire())
results = []
subprocess.run([controller, "configure-filter"], check=True, capture_output=True, timeout=10)


def configure(settings):
    path = output / "configuration.json"
    path.write_text(json.dumps(settings))
    completed = subprocess.run([controller, "configure-transparent", str(path)],
                               capture_output=True, text=True, timeout=25)
    if completed.returncode != 0:
        raise RuntimeError(completed.stdout)


def request(name, url, expected, explicit=False):
    path = output / (name + ".json")
    arguments = [client, str(path), url]
    if url.startswith("dns:"):
        arguments.append(str(query_path))
    elif explicit:
        arguments.append(str(root / "work/chain-native.json"))
    process = subprocess.Popen(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        process.wait(timeout=18)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        result = {"connected": False, "timed_out": True, "pid": process.pid, "url": url}
    else:
        result = json.loads(path.read_text())
    passed = result["connected"] == expected
    if expected and url.startswith("http"):
        passed = passed and result.get("http_status") == 200
    if expected and "cdn-cgi/trace" in url and result["connected"]:
        response = base64.b64decode(result["response_base64"]).decode()
        passed = passed and f"ip={urlsplit(source['upstream']).hostname}\n" in response
    if expected and url.startswith("resolve:"):
        passed = passed and result.get("addresses") == ["1.1.1.1"]
    if expected and url.startswith("dns:") and result["connected"]:
        answer = dns.message.from_wire(base64.b64decode(result["response_base64"]))
        passed = passed and query.is_response(answer) and answer.rcode() == dns.rcode.NOERROR
    if not expected and result.get("error_code") in [-1022, -1200, -1202]:
        passed = False
    result.update(name=name, passed=passed)
    results.append(result)
    (output / "results.json").write_text(json.dumps(results, indent=2))
    print(json.dumps({"name": name, "passed": passed, "connected": result["connected"]}), flush=True)


def resolution_url():
    return "resolve://ccswitch-" + uuid.uuid4().hex + ".1.1.1.1.sslip.io"


for front in ["socks5h://127.0.0.1:7891", "http://127.0.0.1:7890"]:
    configure({**source, "frontProxy": front})
    prefix = "socks-front" if front.startswith("socks") else "http-front"
    request(prefix + "-exit", "https://www.cloudflare.com/cdn-cgi/trace", True)
    request(prefix + "-http", "http://example.com", True)
    request(prefix + "-wss", "wss://ws.postman-echo.com/raw", True)
    request(prefix + "-system-dns", resolution_url(), True)
    request(prefix + "-dns", "dns://1.1.1.1", True)
    request(prefix + "-explicit", "https://www.cloudflare.com/cdn-cgi/trace", True, explicit=True)

configure({**source, "frontProxy": "http://127.0.0.1:58997"})
for name, url in [("https", "https://example.com"), ("dns", "dns://1.1.1.1"),
                  ("system-dns", resolution_url()), ("ipv4", "http://1.1.1.1/cdn-cgi/trace"),
                  ("ipv6", "http://[2606:4700:4700::1111]/cdn-cgi/trace")]:
    request("front-unavailable-" + name, url, False)
configure({**source, "upstream": "http://127.0.0.1:58997"})
request("final-unavailable-https", "https://example.com", False)
request("final-unavailable-system-dns", resolution_url(), False)
subprocess.run([controller, "stop-transparent"], check=True, capture_output=True, timeout=15)
request("stopped-https", "https://example.com", False)
request("stopped-system-dns", resolution_url(), False)
request("stopped-ipv4", "http://1.1.1.1/cdn-cgi/trace", False)
request("stopped-ipv6", "http://[2606:4700:4700::1111]/cdn-cgi/trace", False)
subprocess.run(["curl", "--noproxy", "*", "-fsS", "--max-time", "5", "http://127.0.0.1:15721/health"],
               check=True, capture_output=True, timeout=7)
print(str(output), flush=True)
raise SystemExit(0 if all(item["passed"] for item in results) else 1)
