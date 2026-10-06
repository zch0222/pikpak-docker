# 网络容器：PikPak 容器共用它的网络；开启代理时，在这里把客户端的连接透明转给 v2ray
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
# 镜像源，同客户端镜像的 Dockerfile，必须用 http
ARG APT_MIRROR=

RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i -e "s#http://archive.ubuntu.com/ubuntu#${APT_MIRROR}#g" \
               -e "s#http://security.ubuntu.com/ubuntu#${APT_MIRROR}#g" \
            /etc/apt/sources.list.d/ubuntu.sources; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip iptables tzdata \
 && rm -rf /var/lib/apt/lists/*

# 安装 v2ray（v2fly/v2ray-core）：vendor/ 里有 v2ray-linux-64.zip 就用它，否则从 GitHub 下载
ARG V2RAY_VERSION=5.53.0
ARG V2RAY_URL=https://github.com/v2fly/v2ray-core/releases/download/v${V2RAY_VERSION}/v2ray-linux-64.zip
ARG V2RAY_SHA256=
RUN --mount=type=bind,source=vendor,target=/tmp/vendor \
    set -eu; \
    zip=/tmp/vendor/v2ray-linux-64.zip; \
    if [ ! -f "$zip" ]; then \
        echo "vendor/ 里没有 v2ray-linux-64.zip，从 $V2RAY_URL 下载"; \
        zip=/tmp/v2ray.zip; \
        curl -fL --retry 3 --retry-delay 5 -o "$zip" "$V2RAY_URL"; \
    fi; \
    if [ -n "$V2RAY_SHA256" ]; then \
        echo "$V2RAY_SHA256  $zip" | sha256sum -c -; \
    else \
        echo "没有设置 V2RAY_SHA256，跳过校验。本次安装包的 sha256："; sha256sum "$zip"; \
    fi; \
    unzip -q -o "$zip" v2ray geoip.dat geosite.dat -d /tmp/v2ray; \
    install -m 0755 /tmp/v2ray/v2ray /usr/local/bin/v2ray; \
    install -d /usr/local/share/v2ray; \
    install -m 0644 /tmp/v2ray/geoip.dat /tmp/v2ray/geosite.dat /usr/local/share/v2ray/; \
    rm -rf /tmp/v2ray /tmp/v2ray.zip; \
    v2ray version | head -n 1

# v2ray 用单独的用户运行，防火墙规则靠这个 uid 区分"v2ray 自己的连接"，不能和客户端的 uid（1000）相同
ARG V2RAY_UID=990
RUN groupadd -r -g "$V2RAY_UID" v2ray \
 && useradd -r -u "$V2RAY_UID" -g v2ray -M -d /nonexistent -s /usr/sbin/nologin v2ray

COPY net/pikpak-net /usr/local/bin/pikpak-net
RUN chmod 0755 /usr/local/bin/pikpak-net

ENV V2RAY_LOCATION_ASSET=/usr/local/share/v2ray \
    TZ=Asia/Shanghai

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD ["pikpak-net", "health"]

ENTRYPOINT ["/usr/local/bin/pikpak-net"]
CMD ["start"]
