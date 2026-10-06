#!/usr/bin/env bash
# v2ray 透明代理的端到端测试。只用网络容器镜像，不需要客户端镜像，也不需要真实节点。
#
# 在两个临时 Docker 网络里起四个容器：
#   wan 网络 198.18.0.0/24（不属于内网网段，访问它要走代理），lan 网络（Docker 分配的内网网段）
#   web     代替外网服务器：HTTP 80 端口；UDP 9998、9999 端口把收到的数据记下来
#   server  v2ray 服务端（VMess + WebSocket，用同一个镜像里的 v2ray），把 PikPak 的域名解析到 web
#   net     网络容器，V2RAY_ENABLED=true，配置由 v2ray/v2ray.example.json 改出来（只换节点）；
#           容器参数和 docker-compose.yml 相同
#   client  共用 net 的网络，以 uid 1000 运行，代替客户端
# 结束时删掉全部容器和网络，不影响正在运行的 pikpak、pikpak-net。
#
# 用法：scripts/test-v2ray.sh [网络容器镜像]
# 默认镜像 pikpak-docker-net:<.env 里的 V2RAY_VERSION>，没有的话先执行 docker compose build net
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE=${1:-pikpak-docker-net:$(env_get V2RAY_VERSION 5.53.0)}
BUSYBOX=busybox:1.37
P=pikpak-v2ray-test-$$
WAN=198.18.0
WEB=$WAN.10
SERVER=$WAN.2
UUID=8a0e8f62-3f1c-4d3e-9a57-6f2b1c0d4e11
# PikPak 的 API 域名；客户端这边把它解析到一个不存在的地址，证明连接是按域名交给服务端的
DOMAIN=api-drive.mypikpak.com
BOGUS_IP=203.0.113.1
# web 的首页内容
MARK=pikpak-v2ray-test-ok

"$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || die "没有镜像 $IMAGE，先执行 docker compose build net"

tmp=$(mktemp -d)
cleanup() {
    "$DOCKER" rm -f "$P-client" "$P-net" "$P-server" "$P-web" >/dev/null 2>&1 || true
    "$DOCKER" network rm "$P-wan" "$P-lan" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

failed=0
pass() { printf '  通过  %s\n' "$*"; }
fail() { printf '  失败  %s\n' "$*"; failed=$((failed + 1)); }
check() {
    local desc=$1
    shift
    if "$@" >/dev/null; then pass "$desc"; else fail "$desc"; fi
}
not() { ! "$@"; }

wait_until() {
    local _
    for _ in $(seq 1 "$1"); do
        "${@:2}" && return 0
        sleep 1
    done
    return 1
}

# 在客户端容器里执行（uid 1000，网络和 net 共用）
in_client() { "$DOCKER" exec "$P-client" "$@"; }
client_get() { in_client curl -fsS --max-time 8 "$@" 2>/dev/null; }
client_gets_web() { [ "$(client_get "$@" || true)" = "$MARK" ]; }
server_log_has() { "$DOCKER" logs "$P-server" 2>&1 | grep -qF "$1"; }
net_log_has() { "$DOCKER" logs "$P-net" 2>&1 | grep -qF "$1"; }
v2ray_up() { "$DOCKER" exec "$P-net" pikpak-net health >/dev/null 2>&1; }
# 客户端容器判断 v2ray 是否就绪用的函数（rootfs/usr/local/lib/pikpak/common.sh 的 proxy_ready）
client_sees_proxy() { in_client sh -c '. /common.sh && proxy_ready'; }

# via_server <URL> <服务端日志里的目标> [curl 参数...]：拿到 web 的内容，并且经过了服务端
via_server() {
    local url=$1 target=$2
    shift 2
    client_gets_web "$@" "$url" && server_log_has "tcp:$target"
}
# direct <URL> <目标>：拿到 web 的内容，并且没有经过服务端
direct() { client_gets_web "$1" && not server_log_has "tcp:$2"; }

udp_received() { [ -n "$("$DOCKER" exec "$P-web" cat "/tmp/udp$1" 2>/dev/null)" ]; }
# 9998 是对照：从不在代理后面的服务端容器发出；9999 从客户端容器发出
udp_blocked() { udp_received 9998 && not udp_received 9999; }

recovers() { wait_until 15 v2ray_up && wait_until 10 client_gets_web "http://$WEB/"; }

echo "准备测试环境（镜像 $IMAGE）"
mkdir -p "$tmp/client" "$tmp/server"
chmod 0755 "$tmp" "$tmp/client" "$tmp/server"

# 客户端配置：示例文件只换节点（地址、端口、id），服务端没有 TLS，把 tls 改成 none
sed -e "s/\"address\": \"proxy.example.com\"/\"address\": \"$SERVER\"/" \
    -e 's/"port": 443/"port": 10086/' \
    -e "s/00000000-0000-0000-0000-000000000000/$UUID/" \
    -e 's/"security": "tls"/"security": "none"/' \
    "$ROOT_DIR/v2ray/v2ray.example.json" > "$tmp/client/v2ray.json"
[ "$(grep -c -e "$SERVER" -e '"port": 10086' -e "$UUID" -e '"security": "none"' "$tmp/client/v2ray.json")" -eq 4 ] \
    || die "v2ray.example.json 的格式变了，测试脚本里改节点的 sed 需要跟着改"

cat > "$tmp/server/server.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "hosts": { "$DOMAIN": "$WEB" } },
  "inbounds": [
    {
      "port": 10086,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$UUID" } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/ray" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } } ]
}
EOF
chmod 0644 "$tmp/client/v2ray.json" "$tmp/server/server.json"

"$DOCKER" network create --subnet "$WAN.0/24" "$P-wan" >/dev/null
"$DOCKER" network create "$P-lan" >/dev/null

"$DOCKER" run -d --name "$P-web" --network "$P-wan" --ip "$WEB" "$BUSYBOX" sh -c '
    mkdir -p /www && echo '"$MARK"' > /www/index.html && httpd -p 80 -h /www
    nc -lu -p 9998 > /tmp/udp9998 &
    nc -lu -p 9999 > /tmp/udp9999 &
    trap "exit 0" TERM; while :; do sleep 1; done' >/dev/null
"$DOCKER" network connect "$P-lan" "$P-web"
WEB_LAN=$("$DOCKER" inspect -f "{{(index .NetworkSettings.Networks \"$P-lan\").IPAddress}}" "$P-web")

"$DOCKER" run -d --name "$P-server" --network "$P-wan" --ip "$SERVER" \
    -v "$tmp/server:/etc/v2ray-server:ro" --entrypoint v2ray "$IMAGE" run -c /etc/v2ray-server/server.json >/dev/null

"$DOCKER" run -d --name "$P-net" --hostname pikpak --network "$P-wan" \
    -e V2RAY_ENABLED=true -v "$tmp/client:/etc/v2ray:ro" \
    --read-only --tmpfs /run --tmpfs /tmp \
    --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges:true "$IMAGE" >/dev/null
"$DOCKER" network connect "$P-lan" "$P-net"

"$DOCKER" run -d --name "$P-client" --network "container:$P-net" --user 1000:1000 \
    --cap-drop ALL --security-opt no-new-privileges:true \
    -v "$ROOT_DIR/rootfs/usr/local/lib/pikpak/common.sh:/common.sh:ro" \
    --entrypoint sh "$IMAGE" -c 'trap "exit 0" TERM; while :; do sleep 1; done' >/dev/null

wait_until 30 v2ray_up || {
    "$DOCKER" logs "$P-net" >&2
    die "网络容器里的 v2ray 30 秒内没有就绪"
}

echo
echo "代理正常时"
check "客户端容器认为 v2ray 已就绪（common.sh 的 proxy_ready）" client_sees_proxy
check "访问外网地址成功，经过了服务端" via_server "http://$WEB/" "$WEB:80"
check "HTTP 按域名交给服务端：$DOMAIN 由服务端解析，客户端这边的解析结果没有用到" \
    via_server "http://$DOMAIN/" "$DOMAIN:80" --resolve "$DOMAIN:80:$BOGUS_IP"
# web 没有 HTTPS，这个请求本身会失败，只看服务端收到的目标
in_client curl -sk --max-time 8 -o /dev/null --resolve "$DOMAIN:443:$BOGUS_IP" "https://$DOMAIN/" || true
check "HTTPS 按域名（TLS SNI）交给服务端：服务端日志里有 $DOMAIN:443" server_log_has "tcp:$DOMAIN:443"
check "访问内网地址（$WEB_LAN）直连，不经过服务端" direct "http://$WEB_LAN/" "$WEB_LAN:"
check "Docker 的 DNS 能用" in_client getent hosts "$P-web"
"$DOCKER" exec "$P-server" bash -c "echo control > /dev/udp/$WEB/9998"
in_client bash -c "echo leaked > /dev/udp/$WEB/9999" 2>/dev/null || true
sleep 1
check "UDP 被拒绝：客户端发出的 UDP 没有到达（对照：不在代理后面的容器发的能到达）" udp_blocked

echo
echo "节点连不上时（停掉服务端）"
"$DOCKER" stop -t 1 "$P-server" >/dev/null
check "客户端断网，没有退回直连" not client_get "http://$WEB/"
"$DOCKER" start "$P-server" >/dev/null
check "服务端恢复后客户端恢复联网" wait_until 15 client_gets_web "http://$WEB/"

echo
echo "v2ray 停止时（v2ray.json 不见了，再让 v2ray 重新加载，和 ppctl.sh restart v2ray 相同）"
mv "$tmp/client/v2ray.json" "$tmp/client/v2ray.json.off"
"$DOCKER" kill -s HUP "$P-net" >/dev/null
check "v2ray 停止，网络容器健康检查失败" wait_until 15 not v2ray_up
check "客户端容器认为 v2ray 未就绪" not client_sees_proxy
check "客户端断网，没有退回直连" not client_get "http://$WEB/"
check "网络容器日志说明了原因" net_log_has "找不到 v2ray/v2ray.json"
mv "$tmp/client/v2ray.json.off" "$tmp/client/v2ray.json"
"$DOCKER" kill -s HUP "$P-net" >/dev/null
check "配置放回去并重新加载后，几秒内恢复" recovers

echo
if [ "$failed" -eq 0 ]; then
    echo "全部通过"
else
    echo "$failed 项失败。服务端日志："
    "$DOCKER" logs "$P-server" 2>&1 | tail -n 20
    echo "网络容器日志："
    "$DOCKER" logs "$P-net" 2>&1 | tail -n 20
    exit 1
fi
