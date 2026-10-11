#!/usr/bin/env bash
# 代理节点 v2：起 xray（尽量开 hy2 直连口 + 一定开 ws 备用口）、接 Tailscale 私有网、
# 可选挂一条 Cloudflare 快速隧道作备用，最后把出口证据和客户端参数打全。
#
# 为什么走 Tailscale：快速隧道每次给你随机 trycloudflare 域名，而且完整节点链接会落在
# 公开仓日志里（全世界能看）。走私有网这两条都不存在，还少一层中转。
#
# 关于 hy2 的传输名：Xray 在 25.x 之后把 http 传输改名成 xhttp，不同版本认的不一样。
# 我不在本机验证（下载第三方二进制被安全闸拦了），所以这里不猜 —— 按顺序试，
# 哪个起得来就用哪个，并把赢家打在日志里，下次不用再试。
set -uo pipefail

# 先把仓库根目录存下来：下面会 cd 到临时目录，之后再写 scripts/... 就找不着了
REPO_DIR="$(pwd)"
RENDER="$REPO_DIR/scripts/render-xhs-config.sh"

WORK="${RUNNER_TEMP:-/tmp}/proxy2"
mkdir -p "$WORK"
cd "$WORK"

UUID="$(cat /proc/sys/kernel/random/uuid)"
PATHX="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
DEV="${TS_HOSTNAME:-gha-proxy}"
MIN="${SESSION_MINUTES:-55}"

echo "== 1. 装 xray =="
curl -fsSL --retry 3 -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -qo xray.zip
chmod +x xray
XV="$(./xray version 2>&1 | head -1)"
echo "  $XV"

echo "== 2. 来自签证书（hy2 需要 TLS；客户端用 skip-cert-verify 连）=="
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
  -days 365 -subj "/CN=$DEV" >/dev/null 2>&1 && echo "  证书已生成" || echo "  ::warning::证书生成失败，hy2 这条路会放弃"

TLS='{"certificates":[{"certificateFile":"cert.pem","keyFile":"key.pem"}]}'
WS_SS="{\"network\":\"ws\",\"wsSettings\":{\"path\":\"/$PATHX\"}}"

# 探测一份配置能不能跑：$1 = 直连入口的 streamSettings（空 = 只留 ws 一个入口）
#
# 判定只用 xray 自己的退出码，不去 grep 日志 —— 上一版就是栽在这儿：
# xray 的告警行长这样「[Warning] common/errors: The feature WebSocket transport ... deprecated」,
# 日志包名 common/errors 里含 "error" 子串，于是三份全都正常的配置被我一律判成失败，
# 而紧接着那行 [Warning] core: Xray started 才反映真实结果。别再用子串猜成败。
probe_config() {
  rm -f config.json xray.log
  if ! bash "$RENDER" "$1" "$UUID" "$WS_SS" > config.json; then
    echo "  · 配置渲染失败（$RENDER）"
    return 1
  fi
  if ! python3 -c 'import json;json.load(open("config.json"))' >/dev/null 2>&1; then
    echo "  · 渲染结果不是合法 JSON："
    head -c 300 config.json | sed 's/^/      /'
    return 1
  fi
  # timeout 到点杀进程返回 124 —— 撑满 5 秒说明 xray 正常跑着；其他退出码才是真失败
  timeout 5 ./xray run -c config.json > xray.log 2>&1
  rc=$?
  if [ $rc -eq 124 ]; then
    return 0
  fi
  echo "  · xray 拒绝这份配置（退出码 $rc），关键日志行："
  grep -a -E 'Failed|error:|invalid|unknown|bind|permission|not found' xray.log | head -3 | sed 's/^/      /'
  [ -s xray.log ] || echo "      （日志为空）"
  return 1
}

# 选定后正式常驻启动，并用 PID 而不是进程名来判断它还活着
start_final() {
  nohup ./xray run -c config.json > xray.log 2>&1 &
  XRAY_PID=$!
  sleep 2
  kill -0 "$XRAY_PID" 2>/dev/null
}

echo "== 3. 挑一个能起来的 xray 配置 =="
DIRECT_LABEL=""
DIRECT_NET=""
for cand in \
  "{\"network\":\"xhttp\",\"security\":\"tls\",\"tlsSettings\":$TLS,\"xhttpSettings\":{\"path\":\"/$PATHX\",\"host\":\"$DEV\"}}|xhttp(hy2 新名)" \
  "{\"network\":\"http\",\"security\":\"tls\",\"tlsSettings\":$TLS,\"httpSettings\":{\"path\":\"/$PATHX\",\"host\":\"$DEV\"}}|http(hy2 旧名)" \
  "|不开直连口，只用 ws"; do
  ss="${cand%%|*}"; label="${cand##*|}"
  if probe_config "$ss"; then
    if start_final; then
      DIRECT_LABEL="$label"
      case "$label" in
        xhttp*) DIRECT_NET="xhttp" ;;
        http*)  DIRECT_NET="h2" ;;
        *)      DIRECT_NET="" ;;
      esac
      echo "  ✔ 采用：$label（xray pid=$XRAY_PID）"
      break
    fi
    echo "  ✘ 探测通过但常驻启动失败：$label"
  else
    echo "  ✘ 不行：$label"
  fi
done
[ -z "$DIRECT_LABEL" ] && { echo "::error::xray 三种配置都没能用上，最后一次的日志："; cat xray.log; exit 1; }
echo "  xray 在跑：ws 口 = 127.0.0.1:7890（服务备用隧道）；直连口 = ${DIRECT_LABEL}"

echo "== 4. 接 Tailscale 私有网 =="
TSIP=""
# Windows runner 上不需要 sudo（服务是机器级的，我那套 ps1 就是这么跑通的），
# 但 Linux 上 tailscaled 是 systemd 服务，非 root 改配置会被拒：
#   Access denied: checkprefs access denied / Use 'sudo tailscale up ...'
# GitHub 的 ubuntu runner 有免密 sudo，所以探测一下能不能用，能用就带上。
SUDO=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo"
  echo "  可用免密 sudo，tailscale 命令将带 sudo 执行"
else
  echo "  ::warning::没有免密 sudo，tailscale 可能起不来"
fi
if [ -z "${TS_AUTHKEY:-}" ]; then
  echo "  没设 TS_AUTHKEY，跳过 —— 只能用下面的备用隧道"
else
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
  if command -v tailscale >/dev/null 2>&1; then
    echo "  $($SUDO tailscale version 2>&1 | head -1)"
    $SUDO tailscale up --auth-key="$TS_AUTHKEY" --hostname="$DEV" --accept-dns=false --timeout=2m > ts.log 2>&1 || {
      rc=$?
      if ! grep -q 'Access denied' ts.log; then
        echo "  第一次没成，带 --reset 重试（这版 CLI 要求列全非默认参数）"
        $SUDO tailscale up --auth-key="$TS_AUTHKEY" --hostname="$DEV" --accept-dns=false --timeout=2m --reset > ts2.log 2>&1 || true
      else
        echo "  ::error::sudo 也还是被拒，退出码 $rc"
      fi
    }
    sed -i "s/$TS_AUTHKEY/<已隐去>/g" ts.log ts2.log 2>/dev/null || true
    grep -v '^$' ts.log 2>/dev/null | head -3 | sed 's/^/    /'
    TSIP="$($SUDO tailscale ip -4 2>/dev/null | head -1 || true)"
    if [ -z "$TSIP" ]; then
      echo "  ::warning::没拿到 100.x 地址。tailscale status："
      tailscale status 2>&1 | head -6 | sed 's/^/    /'
    else
      echo "  本机私有网地址 = $TSIP"
    fi
  else
    echo "  ::warning::Tailscale 装完找不到命令，放弃这条路"
  fi
fi

echo "== 5. 备用：Cloudflare 快速隧道 =="
CFHOST=""
curl -fsSL --retry 3 -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared
nohup ./cloudflared tunnel --no-autoupdate --url http://127.0.0.1:7890 > cf.log 2>&1 &
for _ in $(seq 1 30); do
  CFHOST="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' cf.log 2>/dev/null | head -1 | sed 's#https://##' || true)"
  [ -n "$CFHOST" ] && break
  sleep 2
done
[ -n "$CFHOST" ] && echo "  备用隧道 = $CFHOST" || echo "  备用隧道没起来（不影响 Tailscale 主路）"

echo "== 6. 出口体检：你出去的 IP 是谁家的 =="
curl -s --max-time 20 https://ipinfo.io/json | tr -d '\n' | cut -c1-300 | sed 's/^/  /'
echo "  （归属是 Microsoft/Azure 机房 —— 这就是很多站点弹 CF 盾的原因，与传输协议无关）"

echo ""
echo "############### 客户端参数 ###############"
echo "  xray 版本 $XV ｜ 直连入口用的是 $DIRECT_LABEL"
# 下面不再无条件打印 UUID 和路径 —— 公开仓里只要给出「主机 + UUID + 路径」这三样，
# 别人自己就能拼出可用链接，所谓「不打印完整链接」就成了一句空话。
# 规则按可达性来：方式 A 的地址是私有网 100.x，出了你 tailnet 谁都连不到，所以敢全打；
# 方式 B 的地址是公网域名，参数就默认遮掉，要看得把 show_cf_link 选 1。
echo ""
if [ -n "$TSIP" ] && [ -n "$DIRECT_NET" ]; then
  echo "  ── 方式 A：Tailscale 直连 + hy2（推荐）──"
  echo "  mihomo / Clash Verge 的 YAML："
  echo "  proxies:"
  echo "    - name: Actions-TS"
  echo "      type: vless"
  echo "      server: $TSIP"
  echo "      port: 8443"
  echo "      uuid: $UUID"
  echo "      tls: true"
  echo "      skip-cert-verify: true"
  echo "      servername: $DEV"
  echo "      network: $DIRECT_NET   # 服务端这次赢的是 $DIRECT_LABEL；若客户端不认，把这三行换成 http / h2 / xhttp 试"
  # 参数块的名字跟着传输名走：xhttp 用 xhttp-opts，h2/http 用 h2-opts / http-opts
  case "$DIRECT_NET" in
    xhttp) OPTS="xhttp-opts" ;;
    http)  OPTS="http-opts" ;;
    *)     OPTS="h2-opts" ;;
  esac
  echo "      $OPTS:"
  echo "        path: /$PATHX"
  echo "        host: $DEV"
  echo "  手动填：地址 $TSIP:8443 / 传输 http(hy2) / TLS 开并跳过证书校验 / SNI $DEV"
  echo ""
fi
echo "  ── 方式 B：Cloudflare 快速隧道 + ws ──"
if [ -n "$CFHOST" ]; then
  if [ "${SHOW_CF_LINK:-0}" = "1" ]; then
    echo "  地址 $CFHOST:443 / 传输 ws / 路径 /$PATHX / TLS 开 / 无需跳过证书（CF 的正常证书）"
    echo "  UUID $UUID"
    echo "  完整链接：vless://$UUID@$CFHOST:443?encryption=none&security=tls&type=ws&path=%2F$PATHX&sni=$CFHOST#Actions备用"
  else
    echo "  地址 $CFHOST:443 / 传输 ws / TLS 开（CF 的正常证书，无需跳过校验）"
    echo "  路径 /$(printf '%s' "$PATHX" | cut -c1-2)****（隐去） UUID $(printf '%s' "$UUID" | cut -c1-4)****（隐去）"
    echo "  这是公网可达的入口，参数默认不整份打印。要用这条路就触发时把 show_cf_link 选 1 —— 反正公开仓的日志谁都能看，选了 1 就等于承认这条链接在本次会话内是公共的。"
  fi
else
  echo "  本次隧道没起来"
fi
echo ""
echo "  会话 $MIN 分钟，到点自动销毁。提前收工：Actions 页面点 Cancel workflow。"
echo "########################################"

sleep $((MIN * 60))
