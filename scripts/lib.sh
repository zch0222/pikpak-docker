# ppctl.sh 用的函数，用 . 引入

DOCKER=${DOCKER:-docker}
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

# 从 .env 里读一个变量的值；只做文本解析，不执行 .env
env_get() {
    local key=$1 default=$2 line="" val
    if [ -f "$ROOT_DIR/.env" ]; then
        line=$(grep -E "^${key}=" "$ROOT_DIR/.env" | tail -n 1 || true)
    fi
    val=${line#*=}
    val=${val%\"}
    val=${val#\"}
    if [ -n "$line" ] && [ -n "$val" ]; then echo "$val"; else echo "$default"; fi
}

CONTAINER=${PIKPAK_CONTAINER:-$(env_get PIKPAK_CONTAINER pikpak)}

ensure_running() {
    local state
    state=$("$DOCKER" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null) \
        || die "找不到容器 $CONTAINER，先执行 docker compose up -d"
    [ "$state" = true ] || die "容器 $CONTAINER 没有在运行"
}

# 和客户端容器共用网络的容器（docker-compose.yml 里的 net 服务），noVNC 端口和 v2ray 都在它上面
net_container() { echo "$CONTAINER-net"; }
