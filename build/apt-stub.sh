#!/bin/sh
# 构建镜像时用空包顶替用不到、但被别的包硬性依赖的软件包，免得 apt 把它们连同各自的依赖一起装进来
# 用法：apt-stub.sh <包名>...（要先 apt-get update）
# 空包的版本、架构、Multi-Arch 和 apt 的候选版本相同，并且 hold 住：
# 架构不同时（比如写成 all），apt 会把空包当成可以"升级"的旧包，又换回真包
set -eu

dir=$(mktemp -d)
for pkg in "$@"; do
    info=$(apt-cache show --no-all-versions "$pkg" 2>/dev/null) || {
        echo "apt 里找不到软件包 $pkg" >&2
        exit 1
    }
    field() { printf '%s\n' "$info" | sed -n "s/^$1: //p" | head -n 1; }
    version=$(field Version)
    arch=$(field Architecture)
    multiarch=$(field Multi-Arch)

    rm -rf "$dir/pkg"
    mkdir -p "$dir/pkg/DEBIAN"
    {
        echo "Package: $pkg"
        echo "Version: $version"
        echo "Architecture: $arch"
        [ -z "$multiarch" ] || echo "Multi-Arch: $multiarch"
        echo "Maintainer: pikpak-docker"
        echo "Description: placeholder, intentionally not installed"
    } > "$dir/pkg/DEBIAN/control"
    dpkg-deb --build "$dir/pkg" "$dir/stub.deb" >/dev/null
    dpkg -i "$dir/stub.deb" >/dev/null
    apt-mark hold "$pkg" >/dev/null
    echo "已用空包顶替 $pkg $version"
done
rm -rf "$dir"
