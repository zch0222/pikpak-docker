#!/bin/sh
# 构建镜像时安装 WineHQ 的 Wine（只装 64 位部分），并去掉 Windows 库里的调试信息
set -eu

pkg=wine-$WINE_BRANCH
key=/etc/apt/keyrings/winehq.asc

install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 --retry-delay 5 -o "$key" https://dl.winehq.org/wine-builds/winehq.key
if [ -n "${WINEHQ_KEY_SHA256:-}" ]; then
    echo "$WINEHQ_KEY_SHA256  $key" | sha256sum -c -
fi
echo "deb [signed-by=$key] https://dl.winehq.org/wine-builds/ubuntu noble main" > /etc/apt/sources.list.d/winehq.list

# PikPak 和它带的组件都是 64 位程序，用不到 32 位的 Wine。
# 但 $pkg（提供 wine、wineserver 命令）硬性依赖 $pkg-i386，装它会拖进整套 i386 库，这里用一个空包顶替
stub=$(mktemp -d)
mkdir "$stub/DEBIAN"
cat > "$stub/DEBIAN/control" <<EOF
Package: $pkg-i386
Version: $WINE_VERSION
Architecture: all
Maintainer: pikpak-docker
Description: placeholder, 32-bit Wine is intentionally not installed
EOF
dpkg-deb --build "$stub" /tmp/wine-i386-stub.deb >/dev/null
dpkg -i /tmp/wine-i386-stub.deb >/dev/null
rm -rf "$stub" /tmp/wine-i386-stub.deb

# 后面几个库在 Wine 的 Recommends 里：字体（freetype、fontconfig）和 X11 扩展，客户端界面要用
apt-get update
apt-get install -y --no-install-recommends \
    "$pkg=$WINE_VERSION" "$pkg-amd64=$WINE_VERSION" \
    libfreetype6 libfontconfig1 libgnutls30t64 \
    libxcomposite1 libxcursor1 libxfixes3 libxi6 libxinerama1 libxrandr2 libxrender1 libxxf86vm1 \
    binutils

# Windows 库带着调试信息，去掉后从约 765 MB 降到约 240 MB。
# Wine 新建环境时会把这些库复制一份到 $WINEPREFIX 里，所以环境目录也跟着变小。
# strip 不动 DOS 头，Wine 识别内置库用的 "Wine builtin DLL" 标记还在
lib=/opt/$pkg/lib/wine/x86_64-windows
find "$lib" -type f -name '*.a' -delete
find "$lib" -type f -exec strip --strip-debug {} +

apt-get purge -y --auto-remove binutils
rm -rf /var/lib/apt/lists/*

ln -s "/opt/$pkg" /opt/wine
/opt/wine/bin/wine --version
