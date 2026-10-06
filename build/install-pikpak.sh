#!/bin/sh
# 构建镜像时从 PikPak 的 Windows 安装包里解出客户端，放到 /opt/pikpak
# 安装包是 electron-builder 打的 NSIS 包，程序本体在 $PLUGINSDIR/app-64.7z 里，直接解压，不用运行 32 位的安装器
set -eu

exe=$(find /tmp/vendor -maxdepth 1 -type f -iname '*.exe' | head -n 1)
if [ -z "$exe" ]; then
    echo "vendor/ 里没有 .exe，从 $PIKPAK_URL 下载"
    exe=/tmp/pikpak-setup.exe
    curl -fL --retry 3 --retry-delay 5 -o "$exe" "$PIKPAK_URL"
fi

if [ -n "${PIKPAK_SHA256:-}" ]; then
    echo "${PIKPAK_SHA256}  ${exe}" | sha256sum -c - || {
        echo "安装包和 PIKPAK_SHA256 对不上。官方地址总是最新版，官方发了新版本时会这样：" >&2
        echo "确认要升级的话，把 .env 里的 PIKPAK_SHA256 改成上面这个文件的 sha256；想留在旧版本，就把旧安装包放进 vendor/" >&2
        exit 1
    }
else
    echo "没有设置 PIKPAK_SHA256，跳过校验。本次安装包的 sha256："
    sha256sum "$exe"
fi

work=$(mktemp -d)
7z e -y -o"$work" "$exe" '$PLUGINSDIR/app-64.7z' >/dev/null
[ -f "$work/app-64.7z" ] || { echo "安装包里没有 \$PLUGINSDIR/app-64.7z，打包方式可能变了" >&2; exit 1; }
7z x -y -o/opt/pikpak "$work/app-64.7z" >/dev/null
rm -rf "$work" /tmp/pikpak-setup.exe
[ -f /opt/pikpak/PikPak.exe ] || { echo "解压后没有找到 PikPak.exe" >&2; exit 1; }

# 重排 exe/dll，让 Wine 能直接 mmap，各进程共享同一份内存（原因见 pe-realign.py）
python3 /tmp/build/pe-realign.py /opt/pikpak | grep -c '已重排' | xargs printf '重排了 %s 个 PE 文件\n'

version=$(grep -o 'PikPak@[0-9.]*' /opt/pikpak/resources/app/out/main.js | head -n 1 | cut -d@ -f2)
electron=$(grep -a -o 'Electron/[0-9.]*' /opt/pikpak/PikPak.exe | head -n 1 | cut -d/ -f2)
printf 'PIKPAK_VERSION=%s\nELECTRON_VERSION=%s\n' "${version:-unknown}" "${electron:-unknown}" > /etc/pikpak-release
echo "已解出 PikPak ${version:-（版本未知）}，Electron ${electron:-（版本未知）}"
