import hashlib
import json
import os
import pathlib
import signal
import sqlite3
import subprocess
import time


root = pathlib.Path(__file__).resolve().parents[1]
source = root / "work/tauri-arm-build/release/bundle/macos/CC Switch.app"
destination = pathlib.Path("/Applications/CC Switch.app")
backup = root / "work" / ("installation-backup-" + time.strftime("%Y%m%d-%H%M%S"))
backup.mkdir(mode=0o700)
executable = destination / "Contents/MacOS/cc-switch"
database = pathlib.Path.home() / ".cc-switch/cc-switch.db"
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)
original_database = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
backup_database = sqlite3.connect(backup / "cc-switch.db")
original_database.backup(backup_database)
backup_database.close()
original_database.close()
os.chmod(backup / "cc-switch.db", 0o600)
subprocess.run(["ditto", str(destination), str(backup / "CC Switch.app")], check=True)
processes = subprocess.run(["pgrep", "-f", "^/Applications/CC Switch.app/Contents/MacOS/cc-switch$"],
                           capture_output=True, text=True)
if processes.returncode != 0:
    raise RuntimeError("没有找到正在运行的 CC Switch")
pids = [int(value) for value in processes.stdout.split()]
for pid in pids:
    os.kill(pid, signal.SIGTERM)
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    running = subprocess.run(["ps", "-p", ",".join(map(str, pids)), "-o", "pid="], capture_output=True)
    if running.returncode != 0:
        break
    time.sleep(0.1)
else:
    raise RuntimeError("原有 CC Switch 尚未退出，安装已停止")

subprocess.run(["ditto", str(source), str(destination)], check=True)
subprocess.run(["open", "-a", str(destination)], check=True)
healthy = False
for _ in range(40):
    response = subprocess.run(["curl", "--noproxy", "*", "-fsS", "--max-time", "1",
                               "http://127.0.0.1:15721/health"], capture_output=True)
    if response.returncode == 0:
        healthy = json.loads(response.stdout).get("status") == "healthy"
        if healthy:
            break
    time.sleep(0.5)
if not healthy:
    processes = subprocess.run(["pgrep", "-f", "^/Applications/CC Switch.app/Contents/MacOS/cc-switch$"],
                               capture_output=True, text=True)
    for value in processes.stdout.split():
        os.kill(int(value), signal.SIGTERM)
    time.sleep(1)
    subprocess.run(["ditto", str(backup / "CC Switch.app"), str(destination)], check=True)
    subprocess.run(["open", "-a", str(destination)], check=True)
    raise RuntimeError("修改版的本地服务没有启动，已重新启动原有版本")

installed_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
source_hash = hashlib.sha256((source / "Contents/MacOS/cc-switch").read_bytes()).hexdigest()
assert installed_hash == source_hash
result = {"installed": True, "healthy": healthy, "sha256": installed_hash, "backup": str(backup)}
(backup / "installation.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result), flush=True)
