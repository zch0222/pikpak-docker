# 开发进度

最后更新：2026-10-06。目标：按 life115-docker 的结构，用 Wine 在容器里运行 PikPak 官方 Windows 客户端，noVNC 访问，支持 v2ray 全局透明代理。

## 当前状态

原来的两个必须修的问题（客户端输出接管道时弹 JavaScript 错误框、字体链接没生效）已经修好，在替身环境里验证过（Wine 10.0 + Electron 33 写的替身程序，见下文"替身环境"）。v2ray 端到端测试通过。

**还没有用真实客户端重新构建验证**：这次是在云端会话里做的，网络策略拦了 `download.mypikpak.net` 和 `dl.winehq.org`，构建不了正式镜像。下一步见"待办"第 1 条。

## 已完成

- 项目结构：Dockerfile（两阶段）、docker-compose.yml、网络容器和 v2ray（照搬 life115-docker，改了名字）、rootfs 启动脚本、宿主机脚本 `scripts/ppctl.sh`、README。
- 客户端：从官方安装包解出 `$PLUGINSDIR/app-64.7z`，不运行 32 位安装器。2.15.2.5868，Electron 43.6.0（Chromium 150），主程序和迅雷下载组件都是 x64，只有 `resources/elevate.exe` 是 32 位。
- Wine：WineHQ 11.0 稳定版只装 64 位部分，`wine-stable-i386` 用空包顶替；Windows 库 strip 后 765 MB → 238 MB（"Wine builtin DLL" 标记保留）。
- `build/pe-realign.py`：把 exe/dll 重排成按 4 KB 对齐，Wine 能直接 mmap，各进程共享页缓存。45 个 PE 文件被重排，耗时约 1 秒，多占约 14 MB 磁盘。
- Wine `shell` 虚拟桌面代替窗口管理器（去掉了 openbox 和 dbus）。
- 客户端输出不再经过 supervisord 的管道：`run-pikpak` 开头 `exec </dev/null >>/tmp/log/pikpak.log 2>&1`，supervisord 里 `stdout_logfile=NONE`；新增 `run-logtrim`（supervisord 程序 `logtrim`），每分钟检查一次，超过 20 MB 转存到 `pikpak.log.1` 再清空。
- 字体链接的 REG_MULTI_SZ 改成每字符一个字节、末尾 `00,00`（.reg 没有 BOM，Wine 按 ANSI 读 hex(7)）。
- `build/install-pikpak.sh` 取 Electron 版本时 `head -n 1`（上一轮已改，随下次构建生效）。
- `scripts/test-v2ray.sh`：v2ray 透明代理的端到端测试，只用网络容器镜像。

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

### 正式镜像（修复前的版本）

- 镜像 2.48 GB：基础软件包层 746 MB、Wine 层 533 MB、客户端 457 MB。
- 容器首次启动（含创建 Wine 环境）约 21 秒进入 healthy；noVNC `vnc.html` 返回 200。

### 替身环境（云端会话，2026-10-06）

正式镜像构建不了（见"当前状态"），改用替身验证修复：

- 测试镜像由正式 Dockerfile 的运行阶段生成，只换两处：Wine 用 Ubuntu 26.04 自带的 10.0（`wineserver` 在 `/usr/lib/x86_64-linux-gnu/wine/`，软链到 `/opt/wine/bin`）；客户端换成 Electron 33.4.11 写的替身程序（启动时写 stdout/stderr、之后每 5 秒写一行、开一个中文标题的窗口），`PikPak.exe` 就是改名的 `electron.exe`。rootfs、supervisord 配置、compose 文件都用仓库里的原样。
- Electron 43.6.0 在这两个 Wine 上开不了窗口：Ubuntu 24.04 的 Wine 9.0 主进程栈溢出（Electron 33 也一样），Wine 10.0 下 `app.whenReady()` 一直不返回。所以替身用 Electron 33 + Wine 10.0。

| 项目 | 修复前的代码 | 修复后的代码 |
|---|---|---|
| 客户端输出 | 弹 "A JavaScript error occurred in the main process / Error: open EBADF"（`console.log` → `process.getStdout`） | 无错误框；stdout、stderr 都写进 `/tmp/log/pikpak.log` |
| Wine 画的中文（按钮、任务栏"开始"按钮、窗口标题） | 方块 | 正常（标题栏、任务栏、"起点"按钮都是中文） |
| `wine reg query` 读回 SystemLink | `N\0o\0t\0o\0…` | `NotoSansCJK-Regular.ttc,Noto Sans CJK SC` |

修复后的其他检查（替身环境，compose 原样启动）：

- 首次启动（含创建 Wine 环境）约 22 秒 healthy；noVNC `vnc.html` 返回 200；`ppctl.sh status`、`screenshot`、`logs`、`vnc` 正常。
- `ppctl.sh restart`：约 15 秒；主进程 pid 更换，旧的渲染、GPU、网络进程全部清掉；新一轮输出追加在同一个日志文件里。
- `ppctl.sh restart all`：两个容器按顺序重启，约 8 秒 healthy，`/tmp/log` 重新建立。
- 日志截断：往 `pikpak.log` 追加 21 MB，一分钟内转存为 `pikpak.log.1` 并清空；客户端之后的输出从文件开头接着写（没有空洞，追加模式在 Wine 下有效），两份文件时间上衔接，没有丢行。
- stdin 改成 `/dev/null` 对客户端没有影响。

### v2ray 端到端测试

`scripts/test-v2ray.sh`（v2ray 5.53.0）15 项全部通过，约 15 秒。服务端是同一镜像里的 v2ray（VMess + WebSocket），"外网"是 198.18.0.0/24 上的 busybox httpd；PikPak 的域名在服务端用 `dns.hosts` 指到这个网站，客户端这边用 `curl --resolve` 解析到不存在的 203.0.113.1。

- 服务端日志：`accepted tcp:198.18.0.10:80`、`accepted tcp:api-drive.mypikpak.com:80`、`accepted tcp:api-drive.mypikpak.com:443`。网络容器这边的日志记的是客户端解析出的 IP（`tcp:203.0.113.1:443 [proxy]`），域名只在服务端日志里出现。
- 反向检查：把测试里的 `V2RAY_ENABLED` 改成 `false`，9 项失败（剩下的内网直连、DNS 等本来就应该通过），说明检查本身有效。
- 另外用 compose 原样启动替身客户端 + 网络容器（开启代理，节点指向同一个测试服务端）：`ppctl.sh status` 显示"代理：开启，v2ray 就绪"；客户端容器里 `curl http://api-drive.mypikpak.com/`（真实 DNS 解析出 43.159.52.123）经服务端拿到测试网站的内容；替身客户端自己发出的 HTTPS（`redirector.gvt1.com:443`）也出现在服务端日志里；`ppctl.sh restart v2ray`、`logs v2ray` 正常。

## 待办

按顺序：

1. **[必须] 重新构建正式镜像，用真实客户端验证。** 需要能访问 `download.mypikpak.net` 和 `dl.winehq.org`。验证：没有 JavaScript 错误框、`/tmp/log/pikpak.log` 里有客户端输出；中文标题/任务栏；`/etc/pikpak-release` 只有两行；`ppctl.sh restart`、`status`、`logs`、`screenshot`、健康检查。
2. 真实客户端开启代理，看节点日志里有 PikPak 的域名（网络层已由 `scripts/test-v2ray.sh` 验证，这里只是确认客户端本身没有绕开的连接，比如 DownloadServer 的 UDP 被拒后能否正常下载）。
3. **镜像精简**（估算可省约 550 MB）：
   - `scrot` → `xwd`（x11-apps）+ netpbm：省 69 MB（scrot 拉进 imlib2、ghostscript、poppler、librsvg）。
   - Ubuntu 的 `novnc` 依赖 `nodejs`、`python3-novnc`（拉进 babel、iso-codes 等），用空包顶替：约 127 MB。
   - Xvfb → libgl1 → Mesa（`mesa-libgallium` + `libllvm20`）：约 180 MB；我们不用 OpenGL，可以考虑空包顶替 `mesa-libgallium`，要验证 Xvfb 不受影响。
   - WineHQ 硬依赖的扫描仪/相机/ALSA 插件（`libsane1`、`libgphoto2-*`、`libasound2-plugins`，后者拉进整套 ffmpeg）：约 180 MB，用空包顶替。
   - 空包的做法和 `install-wine.sh` 里顶替 `wine-stable-i386` 相同，版本取 apt 的候选版本。
4. README 里"资源占用"和"测试情况/已验证"的客户端部分还是占位，按最终实测补上。
5. 待验证（README 里也列了）：登录后的上传下载、断网续传、72 小时稳定性、提示升级时的表现、大文件和长文件名。

## 本机测试环境（Docker Desktop / WSL2）

- 正在运行 `pikpak`、`pikpak-net` 两个容器（`.env` 里用了清华源和随机 VNC 密码；`.env` 不提交）。**它们用的是修复前的镜像**，`docker compose up -d --build` 重新构建后才有这次的修复。
- 实验容器 `pp-lab`（手工装的 Wine，`/opt/pikpak` 原始版、`/opt/pikpak2` 重排版），测完可以 `docker rm -f pp-lab`。
- `vendor/official_PikPak.exe` 已下载（sha256 `37eb31b2…6496b`，和 winget 清单一致），不提交。
