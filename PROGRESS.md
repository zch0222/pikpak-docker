# 开发进度

最后更新：2026-10-06。目标：按 life115-docker 的结构，用 Wine 在容器里运行 PikPak 官方 Windows 客户端，noVNC 访问，支持 v2ray 全局透明代理。

## 当前状态

镜像能构建，容器能启动并通过健康检查，但**还有两个已定位、未修复的问题**（见"待办"第 1、2 条），修好并重新构建之前，客户端启动后会弹出 JavaScript 错误框。

## 已完成

- 项目结构：Dockerfile（两阶段）、docker-compose.yml、网络容器和 v2ray（照搬 life115-docker，改了名字）、rootfs 启动脚本、宿主机脚本 `scripts/ppctl.sh`、README。
- 客户端：从官方安装包解出 `$PLUGINSDIR/app-64.7z`，不运行 32 位安装器。2.15.2.5868，Electron 43.6.0（Chromium 150），主程序和迅雷下载组件都是 x64，只有 `resources/elevate.exe` 是 32 位。
- Wine：WineHQ 11.0 稳定版只装 64 位部分，`wine-stable-i386` 用空包顶替；Windows 库 strip 后 765 MB → 238 MB（"Wine builtin DLL" 标记保留）。
- `build/pe-realign.py`：把 exe/dll 重排成按 4 KB 对齐，Wine 能直接 mmap，各进程共享页缓存。45 个 PE 文件被重排，耗时约 1 秒，多占约 14 MB 磁盘。
- Wine `shell` 虚拟桌面代替窗口管理器（去掉了 openbox 和 dbus）。

## 实测数据

### 实验容器（手工搭的 Wine 环境，客户端停在登录页）

| 项目 | 结果 |
|---|---|
| 启动、渲染 | 正常；`--no-sandbox` 必须加 |
| 网页内容的中文、日文、韩文 | 正常，直接用 Noto CJK，不用配字体 |
| Wine 画的窗口标题、任务栏 | 不配字体链接时中文是方块；手工 `reg add` 加 SystemLink 后正常 |
| 鼠标、键盘输入（xdotool 模拟） | 正常 |
| 二维码登录页 | 二维码能从网络加载 |
| 切换简体中文 | 正常，重启后保留 |
| 关闭窗口 | 缩到托盘；点托盘图标能恢复 |
| 命令行入口 | 只处理 `.torrent`、`magnet:`、deeplink，没有上传（看过 `out/main.js`、`376.main.js`、`955.main.js`） |
| 自动升级 | 下载 `PikPakSetup.exe` 后运行；镜像里没有 32 位 Wine，预计装不上（未实测） |

内存（各进程 PSS 合计，登录页）：

| | 主进程 | 渲染 | 网络 | crashpad | Wine 后台 | 合计 |
|---|---|---|---|---|---|---|
| 原始 exe | 658 MB | 707 MB | 254 MB | 248 MB | ~34 MB | ~1.9 GB |
| 重排后 | ~500 MB | ~550 MB | 64 MB | 44 MB | ~34 MB | ~1.2 GB |

- 重排前每个进程都有一份约 240 MB 的主程序私有拷贝（文件对齐 0x200，Wine 只能 read 进匿名内存）。
- 重排后主进程、渲染进程仍各有约 256 MB 全零但已占用的内存：V8 沙箱预留 1 TB 地址空间，Wine 的页属性表（每 4 GB 地址空间 1 MB，`dlls/ntdll/unix/virtual.c` 的 `set_page_vprot`）被整块 memset。Wine master 也没改。试过 `ulimit -v` 逼 V8 退到小预留，太脆弱，放弃。
- `--disable-gpu` 对内存没有影响。

### 正式镜像

- 镜像 2.48 GB：基础软件包层 746 MB、Wine 层 533 MB、客户端 457 MB。
- 容器首次启动（含创建 Wine 环境）约 21 秒进入 healthy；noVNC `vnc.html` 返回 200。

## 待办

按顺序：

1. **[必须] 客户端 stdout/stderr 不能是管道。** supervisord 把输出接成管道，Electron 的 Node 在 Wine 里打开管道句柄报 `Error: open EBADF`（`process.getStderr`），主进程弹出 JavaScript 错误框。已在运行中的容器里验证：输出重定向到普通文件就正常。修法：`run-pikpak` 开头 `exec >>/tmp/log/pikpak.log 2>&1`，supervisord 的 `stdout_logfile=NONE`；再加一个小程序定期截断这个日志（/tmp 是 tmpfs，占内存）。
2. **[必须] 字体链接没生效（REG_MULTI_SZ 编码错）。** `run-pikpak` 的 `multi_sz` 给每个字节补了 `00`，按 UTF-16LE 写；但 .reg 文件没有 BOM，Wine 把 hex(7) 当 ANSI 字节读，存成了 `N\0o\0t\0o\0…`。去掉每字节后面的 `,00` 即可（`wine reg query` 可以核对）。注意 wineserver 运行时注册表在内存里，直接 grep `user.reg`/`system.reg` 看不到刚写的值。
3. `build/install-pikpak.sh` 写 `/etc/pikpak-release` 时 Electron 版本重复了一行（二进制里同一"行"有两处匹配），源码已改成 `head -n 1`，需要重新构建。
4. 修完 1–3 后重新构建，验证：中文标题/任务栏、`ppctl.sh restart`（会先 `wineserver -k`）、`status`、`logs`、`screenshot`、健康检查。
5. **v2ray 端到端测试**：本地临时起一个 v2ray 服务端（VMess + WebSocket，可直接用 `life115-docker-net` 镜像里的 v2ray），客户端配置指向它，确认客户端流量（PikPak 的域名）出现在服务端日志里、UDP 被拒、v2ray 停掉后客户端断网。
6. **镜像精简**（估算可省约 550 MB）：
   - `scrot` → `xwd`（x11-apps）+ netpbm：省 69 MB（scrot 拉进 imlib2、ghostscript、poppler、librsvg）。
   - Ubuntu 的 `novnc` 依赖 `nodejs`、`python3-novnc`（拉进 babel、iso-codes 等），用空包顶替：约 127 MB。
   - Xvfb → libgl1 → Mesa（`mesa-libgallium` + `libllvm20`）：约 180 MB；我们不用 OpenGL，可以考虑空包顶替 `mesa-libgallium`，要验证 Xvfb 不受影响。
   - WineHQ 硬依赖的扫描仪/相机/ALSA 插件（`libsane1`、`libgphoto2-*`、`libasound2-plugins`，后者拉进整套 ffmpeg）：约 180 MB，用空包顶替。
   - 空包的做法和 `install-wine.sh` 里顶替 `wine-stable-i386` 相同，版本取 apt 的候选版本。
7. README 里"资源占用"和"测试情况/已验证"两节还是占位，按最终实测补上。
8. 待验证（README 里也列了）：登录后的上传下载、断网续传、72 小时稳定性、提示升级时的表现、大文件和长文件名。

## 本机测试环境（Docker Desktop / WSL2）

- 正在运行 `pikpak`、`pikpak-net` 两个容器（`.env` 里用了清华源和随机 VNC 密码；`.env` 不提交）。
- 实验容器 `pp-lab`（手工装的 Wine，`/opt/pikpak` 原始版、`/opt/pikpak2` 重排版），测完可以 `docker rm -f pp-lab`。
- `vendor/official_PikPak.exe` 已下载（sha256 `37eb31b2…6496b`，和 winget 清单一致），不提交。
