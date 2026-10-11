#!/usr/bin/env bash
# 本地自测：像 runner 那样在 bash 内部传变量，不把 JSON 塞进 Windows argv
# （Git Bash 会改写含冒号/引号的参数，之前那样测出来的是假故障）
cd "D:/github actions 代理" || exit 1

UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PATHX="6122f9042af5"
DEV="gha-proxy"
TLS='{"certificates":[{"certificateFile":"cert.pem","keyFile":"key.pem"}]}'
WS_SS="{\"network\":\"ws\",\"wsSettings\":{\"path\":\"/$PATHX\"}}"

X1="{\"network\":\"xhttp\",\"security\":\"tls\",\"tlsSettings\":$TLS,\"xhttpSettings\":{\"path\":\"/$PATHX\",\"host\":\"$DEV\"}}"
X2="{\"network\":\"http\",\"security\":\"tls\",\"tlsSettings\":$TLS,\"httpSettings\":{\"path\":\"/$PATHX\",\"host\":\"$DEV\"}}"

OUT="${1:-/tmp}"
bash scripts/render-xhs-config.sh "$X1" "$UUID" "$WS_SS" > "$OUT/case1.json"; echo "case1 rc=$?"
bash scripts/render-xhs-config.sh "$X2" "$UUID" "$WS_SS" > "$OUT/case2.json"; echo "case2 rc=$?"
bash scripts/render-xhs-config.sh ""     "$UUID" "$WS_SS" > "$OUT/case3.json"; echo "case3 rc=$?"
