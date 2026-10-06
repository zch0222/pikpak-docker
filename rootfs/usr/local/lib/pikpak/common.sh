# 容器内各脚本共用的函数，用 . 引入

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

wait_for_x() {
    i=0
    until xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -lt 150 ] || die "X 服务 $DISPLAY 30 秒内没有就绪"
        sleep 0.2
    done
}

proxy_enabled() {
    case ${V2RAY_ENABLED:-false} in
        true | 1 | yes | on) return 0 ;;
        *) return 1 ;;
    esac
}

# v2ray 的透明代理端口 127.0.0.1:12345（十六进制 3039）是否在监听。
# 这个容器和 pikpak-net 共用网络，端口在监听说明那边的防火墙规则已经生效
proxy_ready() {
    grep -q ':3039 00000000:0000 0A' /proc/net/tcp
}

# 开启代理时，等 v2ray 就绪再启动客户端，避免客户端在防火墙规则生效前直连
wait_for_proxy() {
    proxy_enabled || return 0
    i=0
    until proxy_ready; do
        [ $((i % 60)) -ne 0 ] || log "等待 v2ray 就绪，没有就绪前不启动客户端（看 pikpak-net 容器的日志）"
        i=$((i + 1))
        sleep 1
    done
}

# 打印客户端主进程的 PID，没在运行时返回非零
# Wine 里的 exe 都由 wine-preloader 运行，/proc/<pid>/exe 分不出来，只能看命令行：
# 第一个参数是 PikPak.exe，并且没有 --type=（带 --type= 的是渲染、网络、crashpad 等子进程）
client_pid() {
    for p in $(pgrep -u "$(id -u)" -f 'PikPak\.exe'); do
        args=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null) || continue
        case $(printf '%s\n' "$args" | head -n 1) in
            */PikPak.exe | *\\PikPak.exe) ;;
            *) continue ;;
        esac
        printf '%s\n' "$args" | grep -q '^--type=' && continue
        echo "$p"
        return 0
    done
    return 1
}
