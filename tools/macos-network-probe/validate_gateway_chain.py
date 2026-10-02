import argparse
import json
import pathlib
import select
import signal
import subprocess
import time
from urllib.parse import urlsplit


parser = argparse.ArgumentParser()
parser.add_argument("--binary", type=pathlib.Path, required=True)
parser.add_argument("--configuration", type=pathlib.Path, required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()
settings = json.loads(args.configuration.read_text())
args.output.mkdir(parents=True, exist_ok=True)
results = []


def request(address, name, url, expected, exit_ip=None):
    result = subprocess.run([
        "curl", "--noproxy", "", "--proxy", "http://" + address,
        "--silent", "--show-error", "--fail", "--max-time", "20", url,
    ], capture_output=True, text=True, timeout=25)
    passed = (result.returncode == 0) == expected
    if exit_ip and expected:
        passed = passed and "ip=" + exit_ip + "\n" in result.stdout
    record = {"name": name, "passed": passed, "curlStatus": result.returncode}
    results.append(record)
    print(json.dumps(record), flush=True)
    (args.output / "results.json").write_text(json.dumps(results, indent=2))


def validate(name, configuration, expected, exit_ip=None):
    with (args.output / (name + ".stderr")).open("w") as log:
        process = subprocess.Popen([str(args.binary.resolve()), "--stdin"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=log, text=True)
        try:
            process.stdin.write(json.dumps(configuration))
            process.stdin.close()
            ready, _, _ = select.select([process.stdout], [], [], 15)
            if not ready:
                raise RuntimeError("测试转发程序没有启动")
            status = json.loads(process.stdout.readline())
            address = status["address"]
            request(address, name + "-https", "https://www.cloudflare.com/cdn-cgi/trace", expected, exit_ip)
            request(address, name + "-http", "http://example.com", expected)
        finally:
            process.send_signal(signal.SIGINT)
            process.wait(timeout=5)
        request(address, name + "-stopped", "https://example.com", False)


validate("front-omitted", {"upstream": "http://127.0.0.1:7890"}, True)
validate("front-empty", {"upstream": "socks5h://127.0.0.1:7891", "frontProxy": ""}, True)
for name, front in [("socks-front", "socks5h://127.0.0.1:7891"),
                    ("http-front", "http://127.0.0.1:7890")]:
    validate(name, {**settings, "frontProxy": front}, True, urlsplit(settings["upstream"]).hostname)
validate("front-unavailable", {**settings, "frontProxy": "http://127.0.0.1:58997"}, False)
validate("final-unavailable", {"upstream": "http://127.0.0.1:58997"}, False)
subprocess.run(["curl", "--noproxy", "*", "-fsS", "--max-time", "5",
                "http://127.0.0.1:15721/health"], check=True, capture_output=True, timeout=8)
raise SystemExit(0 if all(result["passed"] for result in results) else 1)
