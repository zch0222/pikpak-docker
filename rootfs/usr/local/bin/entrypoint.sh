#!/bin/sh
# 检查必要配置、准备运行目录和 VNC 密码文件，然后启动 supervisord
set -eu
. /usr/local/lib/pikpak/common.sh

[ -n "${VNC_PASSWORD:-}" ] || die "必须设置环境变量 VNC_PASSWORD"
[ -w "$HOME" ] || die "$HOME 不可写（当前 uid=$(id -u)）。用了宿主机目录挂载的话，执行：chown -R $(id -u):$(id -g) <那个目录>"

install -d -m 0700 "$XDG_RUNTIME_DIR"
mkdir -p /tmp/log

# x11vnc 的密码文件：第一行是控制密码，__BEGIN_VIEWONLY__ 之后是只读密码
umask 077
{
    printf '%s\n' "$VNC_PASSWORD"
    if [ -n "${VNC_VIEW_PASSWORD:-}" ]; then
        printf '__BEGIN_VIEWONLY__\n%s\n' "$VNC_VIEW_PASSWORD"
    fi
} > "$XDG_RUNTIME_DIR/vncpasswd"
umask 022

exec "$@"
