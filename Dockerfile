# PikPak 官方 Windows 客户端 + Wine + 虚拟显示器（Xvfb）+ noVNC

# 第一阶段：从官方安装包里解出客户端，并把 exe/dll 重排成按页对齐（原因见 build/pe-realign.py）
FROM ubuntu:24.04 AS app

ARG DEBIAN_FRONTEND=noninteractive
# 可选的 Ubuntu 镜像源，例如 http://mirrors.tuna.tsinghua.edu.cn/ubuntu；国内服务器构建时能快很多
# 必须用 http：这时还没装 CA 证书，https 源会校验失败；软件包由 apt 的签名校验保证完整
ARG APT_MIRROR=

RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i -e "s#http://archive.ubuntu.com/ubuntu#${APT_MIRROR}#g" \
               -e "s#http://security.ubuntu.com/ubuntu#${APT_MIRROR}#g" \
            /etc/apt/sources.list.d/ubuntu.sources; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl p7zip-full python3-minimal \
 && rm -rf /var/lib/apt/lists/*

# vendor/ 里有安装包就用它，否则从官方地址下载。官方地址总是最新版，版本由 PIKPAK_SHA256 锁定
# vendor/ 用挂载而不是 COPY，安装包不会留在镜像层里
ARG PIKPAK_URL=https://download.mypikpak.net/desktop/official_PikPak.exe
ARG PIKPAK_SHA256=
COPY build/install-pikpak.sh build/pe-realign.py /tmp/build/
RUN --mount=type=bind,source=vendor,target=/tmp/vendor \
    sh /tmp/build/install-pikpak.sh


# 第二阶段：运行环境
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG APT_MIRROR=

# 虚拟显示器、VNC/noVNC、进程管理、截图工具、中文字体
# 不需要窗口管理器：Wine 的虚拟桌面自己管理窗口，还带任务栏和托盘
RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i -e "s#http://archive.ubuntu.com/ubuntu#${APT_MIRROR}#g" \
               -e "s#http://security.ubuntu.com/ubuntu#${APT_MIRROR}#g" \
            /etc/apt/sources.list.d/ubuntu.sources; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl tzdata locales procps \
        xvfb x11-utils x11vnc novnc websockify \
        supervisor scrot fonts-noto-cjk \
 && locale-gen zh_CN.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# Wine：WineHQ 的稳定版，只装 64 位部分（见 build/install-wine.sh）
# 换版本时 WINE_VERSION 要写完整的包版本号，可用的版本见 https://dl.winehq.org/wine-builds/ubuntu/dists/noble/main/binary-amd64/
ARG WINE_BRANCH=stable
ARG WINE_VERSION=11.0.0.0~noble-1
ARG WINEHQ_KEY_SHA256=d965d646defe94b3dfba6d5b4406900ac6c81065428bf9d9303ad7a72ee8d1b8
COPY build/install-wine.sh /tmp/install-wine.sh
RUN sh /tmp/install-wine.sh && rm -f /tmp/install-wine.sh

# 所有进程都以普通用户 app 运行；ubuntu 镜像自带的 ubuntu 用户占用了 1000，先删掉
ARG APP_UID=1000
ARG APP_GID=1000
RUN (userdel -r ubuntu 2>/dev/null || true) \
 && groupadd -g "$APP_GID" app \
 && useradd -u "$APP_UID" -g app -d /config -M -s /bin/bash app \
 && install -d -o app -g app -m 0750 /config \
 && install -d -m 0755 /data

COPY --from=app /opt/pikpak /opt/pikpak
COPY --from=app /etc/pikpak-release /etc/pikpak-release

COPY rootfs/ /
RUN chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/run-xvfb \
        /usr/local/bin/run-x11vnc \
        /usr/local/bin/run-pikpak \
        /usr/local/bin/pikpak-screenshot \
        /usr/local/bin/pikpak-status \
 && chmod 0644 /usr/local/lib/pikpak/common.sh /etc/supervisor/pikpak.conf

# WINEDLLOVERRIDES：不装 Wine Mono/Gecko（客户端用不到，装的话首次启动会弹窗），不生成桌面快捷方式
ENV HOME=/config \
    DISPLAY=:99 \
    SCREEN_GEOMETRY=1600x900x24 \
    XDG_RUNTIME_DIR=/tmp/runtime-app \
    LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8 \
    TZ=Asia/Shanghai \
    PATH=/opt/wine/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    WINEPREFIX=/config/.wine \
    WINEARCH=win64 \
    WINEDEBUG=fixme-all \
    WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"

USER app
WORKDIR /config
VOLUME ["/config"]
EXPOSE 6080

# 第一次启动要先创建 Wine 环境，留足时间
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD ["pikpak-status", "-q"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/pikpak.conf"]
