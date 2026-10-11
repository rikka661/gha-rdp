#!/usr/bin/env bash
# 渲染 xray 配置文件（stdout 输出 JSON）。单独成文件是为了让本地能直接拿同一份代码测，
# 不靠复制的副本 —— proxy.yml 那个「连上但没网络」就是配置写错造成的，不能再栽第二次。
#
#   $1 = 直连入口的 streamSettings；传空字符串表示只留 ws 一个入口
#   $2 = UUID
#   $3 = ws 入口的 streamSettings
#
# 要点：inbounds 之外必须有 outbounds(freedom)，否则 xray 起来、握手也成功，
# 但流量进来后无处可去 —— 客户端表现为「连上了但没有网络」。
set -uo pipefail

D="${1:-}"; U="${2:?需要 UUID}"; W="${3:?需要 ws streamSettings}"

printf '{\n'
printf '  "log": { "loglevel": "warning" },\n'
printf '  "inbounds": [\n'
if [ -n "$D" ]; then
  printf '    {"listen": "0.0.0.0", "port": 8443, "protocol": "vless", "settings": {"clients": [{"id": "%s"}], "decryption": "none"}, "streamSettings": %s},\n' "$U" "$D"
fi
printf '    {"listen": "127.0.0.1", "port": 7890, "protocol": "vless", "settings": {"clients": [{"id": "%s"}], "decryption": "none"}, "streamSettings": %s}\n' "$U" "$W"
printf '  ],\n'
printf '  "outbounds": [ { "protocol": "freedom", "settings": {} } ]\n'
printf '}\n'
