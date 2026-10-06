#!/usr/bin/env bash
# PikPak 容器的日常操作：状态、截图、重启、日志、noVNC 地址
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

programs="pikpak xvfb x11vnc novnc"

usage() {
    cat <<EOF
用法: $(basename "$0") [-c 容器名] <命令> [参数]

命令：
  status              各进程状态、客户端和 Wine 版本、代理状态
  screenshot [文件]   保存虚拟显示器截图，默认 ./pikpak-<时间>.png
  restart [程序]      重启容器里的一个程序，默认 pikpak（客户端）；可选：$programs
                      v2ray：重新加载 v2ray/v2ray.json，客户端不用重启
                      all：按顺序重启网络容器和客户端容器
  logs [程序]         持续查看日志，默认 pikpak；可选：$programs v2ray
  vnc                 显示 noVNC 访问地址
  shell               进入容器的 shell
EOF
}

check_program() {
    case " $programs " in
        *" $1 "*) ;;
        *) die "未知程序：$1（可选：$programs）" ;;
    esac
}

if [ "${1:-}" = "-c" ]; then
    CONTAINER=${2:?-c 需要一个参数}
    shift 2
fi
cmd=${1:-}
[ $# -gt 0 ] && shift
NET=$(net_container)

case $cmd in
    status)
        ensure_running
        "$DOCKER" exec "$CONTAINER" pikpak-status
        ;;
    screenshot)
        ensure_running
        out=${1:-./pikpak-$(date +%Y%m%d-%H%M%S).png}
        "$DOCKER" exec "$CONTAINER" pikpak-screenshot - > "$out"
        echo "已保存：$out"
        ;;
    restart)
        target=${1:-pikpak}
        case $target in
            all)
                # 客户端容器用的是网络容器的网络，网络容器重启后客户端容器也必须重启
                "$DOCKER" restart "$NET"
                "$DOCKER" restart "$CONTAINER"
                ;;
            v2ray)
                "$DOCKER" kill -s HUP "$NET" >/dev/null
                echo "已让 v2ray 重新加载配置；结果看：$(basename "$0") logs v2ray"
                ;;
            *)
                ensure_running
                check_program "$target"
                "$DOCKER" exec "$CONTAINER" supervisorctl -c /etc/supervisor/pikpak.conf restart "$target"
                ;;
        esac
        ;;
    logs)
        prog=${1:-pikpak}
        if [ "$prog" = v2ray ]; then
            exec "$DOCKER" logs -f --tail 200 "$NET"
        fi
        ensure_running
        check_program "$prog"
        "$DOCKER" exec "$CONTAINER" tail -n 200 -F "/tmp/log/$prog.log"
        ;;
    vnc)
        addr=$("$DOCKER" port "$NET" 6080/tcp 2>/dev/null | head -n 1 || true)
        [ -n "$addr" ] || die "容器 $NET 没有发布 6080 端口，先执行 docker compose up -d"
        echo "http://$addr/vnc.html?autoconnect=1&resize=scale"
        case $addr in
            127.0.0.1:* | localhost:*) echo "只监听本机。从别的电脑访问：ssh -L ${addr#*:}:127.0.0.1:${addr#*:} <这台服务器>" ;;
        esac
        ;;
    shell)
        ensure_running
        exec "$DOCKER" exec -it "$CONTAINER" bash
        ;;
    '' | -h | --help | help)
        usage
        ;;
    *)
        usage >&2
        die "未知命令：$cmd"
        ;;
esac
