# ASCII only. Reads the newest proxy run's log, spins up a private mihomo instance
# with that node, and prints EVIDENCE only (egress ASN/org + per-site HTTP codes).
# Never prints the node link itself.
import json, os, re, subprocess, sys, tempfile, time

REPO = "rikka661/gha-rdp"


def gh(*args):
    r = subprocess.run(["gh"] + list(args), capture_output=True, text=True, encoding="utf-8", errors="replace")
    return (r.stdout or "").strip(), (r.stderr or "").strip(), r.returncode


def main():
    out, err, code = gh("api", f"repos/{REPO}/actions/runs?per_page=10")
    if code:
        print("FAIL to list runs:", err[:200]); return 1
    runs = [r for r in json.loads(out)["workflow_runs"] if r["name"] == "简易代理（零注册、零 Secrets）" or "proxy" in (r["name"] or "").lower()]
    if not runs:
        runs = json.loads(out)["workflow_runs"]
    run = runs[0]
    print(f"[1] 最近一轮代理: id={run['id']} 状态={run['status']}/{run.get('conclusion') or '-'} 开始={run['created_at']}")
    if run["status"] != "in_progress":
        print("    这轮已经结束了（节点随机器销毁一起失效），请重新 Run workflow 再测一次。")
        return 2

    jout, _, _ = gh("api", f"repos/{REPO}/actions/runs/{run['id']}/jobs")
    job_id = json.loads(jout)["jobs"][0]["id"]
    lout, _, _ = gh("api", f"repos/{REPO}/actions/jobs/{job_id}/logs")
    m = re.findall(r"vless://([^@]+)@([^:]+):443\?[^ \"']*?path=%2F([0-9a-f]+)", lout)
    if not m:
        print("[2] 日志里没解析到节点链接"); return 3
    uuid, host, path = m[-1]
    print(f"[2] 节点已取到（host={host[:14]}***，UUID 与路径只写进本地测试配置，不打印）")

    d = os.path.join(tempfile.gettempdir(), "gha-mshtest")
    os.makedirs(d, exist_ok=True)
    cfg = f"""mixed-port: 17890
allow-lan: false
log-level: warning
proxies:
  - name: gha
    type: vless
    server: {host}
    port: 443
    uuid: {uuid}
    tls: true
    servername: {host}
    network: ws
    ws-opts:
      path: /{path}
      headers:
        Host: {host}
proxy-groups:
  - name: g
    type: select
    proxies: [gha]
rules:
  - MATCH,g
"""
    with open(os.path.join(d, "config.yaml"), "w", encoding="utf-8") as f:
        f.write(cfg)

    exe = r"C:\Program Files\Clash Verge\verge-mihomo.exe"
    logf = os.path.join(d, "m.log")
    open(logf, "w").close()
    with open(logf, "w") as lf:
        p = subprocess.Popen([exe, "-d", d], stdout=lf, stderr=lf, creationflags=0x08000000)
    time.sleep(4)

    def via(url, extra=None):
        a = ["curl.exe", "-s", "-o", "-", "-w", "\n<<%{http_code}>>", "--max-time", "25",
             "-x", "http://127.0.0.1:17890", "-A",
             "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"]
        if extra:
            a += extra
        a.append(url)
        r = subprocess.run(a, capture_output=True, text=True, encoding="utf-8", errors="replace")
        body, _, st = (r.stdout or "").rpartition("\n<<")
        return st.rstrip(">"), (body or "")

    try:
        print("[3] 走节点出国后的出口信息：")
        st, body = via("https://ipinfo.io/json")
        try:
            j = json.loads(body)
            print(f"    出口 IP = {j.get('ip')}   归属 = {j.get('org')}   城市 = {j.get('city')},{j.get('country')}   (HTTP {st})")
        except Exception:
            print(f"    取不到出口信息 (HTTP {st})")

        print("[4] 同样一批站点，走节点的结果对比：")
        targets = [
            ("普通站点 example.com", "https://example.com"),
            ("GitHub API（机房 IP 不设限）", "https://api.github.com/zen"),
            ("Cloudflare 官方挑战页", "https://www.cloudflare.com/cdn-cgi/challenge-platform/h/b/orchestration"),
            ("典型套盾站点 1", "https://temp-mail.org/en/"),
            ("典型套盾站点 2", "https://www.timesandseasons.org/"),
        ]
        for name, u in targets:
            st, body = via(u)
            mark = ""
            if st in ("403", "503"):
                mark = "  <-- 被 CF 盾拦（403/503 是它的典型码）"
            elif st == "000":
                mark = "  <-- 超时"
            print(f"    {name:<28} HTTP {st}{mark}")
    finally:
        subprocess.run(["taskkill", "/PID", str(p.pid), "/F"], capture_output=True)
        print("[5] 测试实例已关闭（没留下常驻进程）")
    return 0


sys.exit(main())
