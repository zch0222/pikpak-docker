# pikpak-docker

在没有显示器的 Linux 服务器上，用 Docker + Wine 运行 PikPak 官方 Windows 客户端，通过浏览器（noVNC）操作；可以让客户端的全部流量经过 v2ray。

> **开发中**：已知问题已修复，但还没有用真实客户端重新构建验证；当前进度和待办见 [PROGRESS.md](PROGRESS.md)。

PikPak 官方只有 Windows 和 macOS 客户端，没有 Linux 版。这里沿用 [life115-docker](../life115-docker) 的结构，把其中的 115 Linux 客户端换成"Wine + PikPak Windows 客户端"，网络容器和 v2ray 代理原样保留。

## 工作方式

```
浏览器 ──SSH 隧道──> noVNC（6082）──> x11vnc ──> Xvfb :99 ──> Wine 虚拟桌面 ──> PikPak.exe
宿主机目录（HOST_DATA_DIR）──读写挂载──> 容器 /data ──Wine──> Z:\data
```

compose 里有两个容器：

- `pikpak`：客户端容器，下面的进程都在这里。
- `pikpak-net`：网络容器。客户端容器共用它的网络，noVNC 端口也发布在它上面。开启 [v2ray 代理](#v2ray-代理) 时，由它把客户端的连接转给 v2ray；不开时它只占住网络，什么也不做。

客户端容器里的进程都由 supervisord 管理，全部以 uid 1000 的普通用户运行：

| 进程 | 作用 |
|---|---|
| Xvfb `:99` | 虚拟显示器 |
| x11vnc | 只监听容器内的 `127.0.0.1:5900` |
| noVNC（websockify） | 浏览器访问入口，容器端口 6080 |
| PikPak（Wine） | 官方客户端和 Wine 的后台进程；崩溃或被关掉后自动拉起 |

### 镜像是怎么做的

- **客户端**：官方安装包是 electron-builder 打的 NSIS 包，程序本体在里面的 `$PLUGINSDIR/app-64.7z`。构建时直接解压到 `/opt/pikpak`，不运行安装器。客户端是 Electron 43（Chromium 150），主程序和它带的迅雷下载组件全是 64 位。
- **Wine**：WineHQ 11.0 稳定版，只装 64 位部分。WineHQ 的 `wine-stable` 包硬性依赖 32 位的 `wine-stable-i386`，这里用一个空包顶替，省掉整套 i386 库。Wine 的 Windows 库带着调试信息，构建时去掉，从约 765 MB 降到约 240 MB。
- **重排 exe/dll**（`build/pe-realign.py`）：客户端的 exe 和 dll 在文件里按 512 字节对齐，Wine 遇到这种文件没法 mmap，只能把整个文件读进每个进程自己的内存。主程序 230 MB，主进程、渲染进程、网络进程、crashpad 各复制一份，多占约 1 GB。构建时把它们重新排成按 4 KB 对齐，Wine 就能直接映射文件，各进程共享同一份页缓存，代码和数据不变。数字签名随之失效，Wine 不校验签名。
- **精简依赖**：Ubuntu 的 noVNC、Xvfb 包硬性依赖 Node.js、Mesa（软件 OpenGL，连带整个 LLVM）等用不到的东西，构建时用空包顶替（`build/apt-stub.sh`），基础软件包从 746 MB 降到 282 MB。客户端加了 `--disable-gpu`，有没有 OpenGL 都只用软件渲染；日志里 Wine 报的几行 OpenGL/D3D 初始化失败可以忽略。
- **虚拟桌面**：Wine 的 `shell` 虚拟桌面铺满整个屏幕，自带任务栏和托盘，所以不需要窗口管理器。客户端点关闭时会缩到托盘，点右下角的托盘图标就能找回来。
- **中文**：客户端界面由 Chromium 渲染，直接使用 Noto CJK 字体。窗口标题和任务栏由 Wine 用 Windows 系统字体（Tahoma 等）绘制，这些字体里没有中文；启动时通过字体链接让它们缺字时回退到 Noto CJK。

## 要求

- x86-64 的 Linux（客户端只有 x64 版）
- Docker 24 以上和 Docker Compose v2
- 给容器预留 1.5–2 GB 内存（见 [资源占用](#资源占用)）

## 快速开始

1. 复制配置文件：

   ```bash
   cp .env.example .env
   ```

   编辑 `.env`：至少设置 `VNC_PASSWORD`。要走代理的话，再看 [v2ray 代理](#v2ray-代理)。

2. 构建并启动：

   ```bash
   docker compose up -d --build
   ```

   构建时要下载 PikPak 安装包（`https://download.mypikpak.net/desktop/official_PikPak.exe`，2.15.2 约 122 MB）、WineHQ 的 Wine（约 120 MB）和 Ubuntu 的软件包。不想在构建时下载 PikPak，就先把 `official_PikPak.exe` 放进 `vendor/`。国内服务器建议在 `.env` 里设置 `APT_MIRROR`。

   **官方下载地址总是最新版。** `.env` 里的 `PIKPAK_SHA256` 锁定了 2.15.2；官方发了新版后，构建会因为 sha256 对不上而失败，见 [升级客户端](#升级客户端)。

3. 第一次启动时要先创建 Wine 环境，大约半分钟后客户端才出现。用 `scripts/ppctl.sh status` 看进度。

4. 打开客户端界面。noVNC 默认只监听服务器本机，从自己电脑访问时先建一条 SSH 隧道：

   ```bash
   ssh -L 6082:127.0.0.1:6082 <服务器>
   ```

   然后浏览器打开 `http://127.0.0.1:6082/vnc.html`，输入 `VNC_PASSWORD`。

5. 登录。可以用手机 PikPak App 扫二维码，也可以用邮箱、手机号登录。界面默认是英文，右上角可以切换成简体中文，设置会保存下来。

## 资源占用

2026-10-06 在 Docker Desktop（WSL2，amd64）上实测，客户端停在登录页：

（实测数据见下文"测试情况"，构建完成后补充）

## 和客户端交换文件

宿主机的 `HOST_DATA_DIR`（默认 `./data`）读写挂载到容器的 `/data`，在客户端里是 `Z:\data`：

- 上传：在客户端里选择上传文件，到 `Z:\data` 下面去选。
- 下载到本地：在客户端设置里把下载目录改到 `Z:\data` 下面，否则默认存在 Wine 环境里（`C:\users\app\Downloads`，在 `pikpak-config` 卷里）。

文件要让 uid 1000 能读到；要在容器里写入，还需要给 uid 1000 写权限，比如 `chown -R 1000:1000 <共享目录>`。

**客户端没有命令行上传的入口。** 它的命令行参数只处理 `magnet:` 链接、`.torrent` 文件和登录用的 `pikpak://` 回调，都是添加云下载任务，不能上传本地文件。要自动上传，只能模拟操作界面（Wine 的窗口是普通的 X11 窗口，可以用 xdotool 操作），这个镜像目前没有做。

## 日常操作 `scripts/ppctl.sh`

| 命令 | 作用 |
|---|---|
| `status` | 各进程状态、客户端和 Wine 版本、代理状态 |
| `screenshot [文件]` | 保存虚拟显示器截图，不开浏览器也能看到客户端当前画面 |
| `restart [程序]` | 重启客户端（默认），或 `xvfb`/`x11vnc` 等；`v2ray` 重新加载 `v2ray.json`；`all` 按顺序重启网络容器和客户端容器 |
| `logs [程序]` | 持续查看日志，默认看客户端；`v2ray` 看网络容器的日志 |
| `vnc` | 显示 noVNC 地址 |
| `shell` | 进入容器 |

重启客户端时，会先把整个 Wine 会话清掉（包括上一轮遗留的子进程），再重新启动。

客户端的日志在容器的 `/tmp/log/pikpak.log`（内存盘）。超过 20 MB 时转存为 `pikpak.log.1` 再清空，最多占用约 40 MB 内存。

## v2ray 代理

打开后，客户端的全部网络连接（登录、上传、下载、界面里的网页）都经过 v2ray。这是透明代理，不需要在客户端里设置代理；客户端登录页右上角的"代理"选项不用填，两边都设反而容易出问题。

### 开启

1. 复制节点配置，把 `outbounds` 里的 `proxy` 换成你的节点：

   ```bash
   cp v2ray/v2ray.example.json v2ray/v2ray.json
   ```

2. `.env` 里设置 `V2RAY_ENABLED=true`。
3. 执行 `docker compose up -d`。两个容器会按顺序重建，登录状态不受影响。
4. 确认生效：

   ```bash
   scripts/ppctl.sh status                          # 应显示"代理：开启，v2ray 就绪"
   docker exec pikpak curl -s https://api.ipify.org  # 应显示代理的出口 IP
   ```

关闭时把 `V2RAY_ENABLED` 改回 `false`，再执行 `docker compose up -d`。

### `v2ray.json` 怎么写

- **`transparent` 入站保持原样**（`dokodemo-door`，监听 `127.0.0.1:12345`，`followRedirect: true`）。客户端的连接就是转到这个端口的。
- **代理出站的 `tag` 保持 `proxy`**。示例里是 VMess + WebSocket + TLS。可以从 v2rayN 等客户端导出的配置里，把节点对应的 outbound 对象整个复制过来替换，再把 `tag` 改成 `proxy`。
- **`routing` 里那条规则把透明代理入站的流量全部交给 `proxy`，也就是全局代理。**
- 用的是 v2fly 的 v2ray-core 5.x，配置格式和常见的 v2ray 配置文件相同。**它不支持 Xray 专有的 REALITY、XTLS Vision**；节点用的是这两种时，需要把镜像里的 v2ray 换成 Xray。
- v2ray 在容器里以 uid 990 运行，文件要让它能读到。服务器上可以执行 `chown 990 v2ray/v2ray.json && chmod 600 v2ray/v2ray.json`。
- 文件里有节点密钥，已经在 `.gitignore` 里，不会被提交。

### 规则

| 流量 | 处理 |
|---|---|
| TCP | 全部转给 v2ray；v2ray 自己发出的连接除外 |
| 访问本机、内网地址 | 不走代理 |
| DNS | 放行，用 Docker 的 DNS 解析 |
| 其他 UDP、ICMP、IPv6 | 拒绝 |

这样客户端只能经过 v2ray 联网。**v2ray 停了、节点连不上、配置写错时，客户端会断网，不会退回直连。**

DNS 虽然在本地解析，但 v2ray 会从连接里识别出域名（sniffing），把域名交给代理服务器去解析。所以最终连到的是代理那边解析出的地址。

客户端带的迅雷下载组件（`DownloadServer.exe`）会用 UDP 做 P2P。开启代理时 UDP 被拒绝，它只能走 HTTP；不影响网盘的上传下载。

### 日常操作

- 改了 `v2ray.json`：执行 `scripts/ppctl.sh restart v2ray`，只重新加载 v2ray，客户端不断开。配置有错误时，日志里会说明原因；改好后几秒内自动恢复。
- 查看 v2ray 日志：`scripts/ppctl.sh logs v2ray`。每个连接都会记一行访问日志，比如 `accepted tcp:… [proxy]`，可以确认流量确实走了代理。这里记的是客户端解析出的 IP，域名要在节点那边的日志里看。日志最多保留 30 MB。
- **不要单独重启 `pikpak-net` 容器**：客户端容器用的是它的网络，它一重启，客户端容器就只剩本机回环、彻底断网。要重启就用 `scripts/ppctl.sh restart all` 或 `docker compose restart`。
- 开启代理时，客户端会等 v2ray 就绪后才启动。

### 测试

`scripts/test-v2ray.sh` 在本机临时起一个 v2ray 服务端和一个代替外网服务器的小网站，检查上面的规则是否生效。只用网络容器的镜像（没有的话先 `docker compose build net`），不需要客户端镜像和真实节点，也不影响正在运行的容器，十几秒跑完：

```bash
scripts/test-v2ray.sh
```

它检查：TCP 连接经过服务端；PikPak 的域名（HTTP 的 Host、HTTPS 的 SNI）原样交给服务端解析；内网地址直连；DNS 正常；UDP 被拒绝；服务端停掉、v2ray 停止时客户端断网，恢复后自动恢复联网。

## 配置项（`.env`）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PIKPAK_CONTAINER` | `pikpak` | 容器名 |
| `PIKPAK_SHA256` | 2.15.2 的值 | 安装包 sha256，决定用哪个版本（官方地址总是最新版）；留空则只打印、不校验 |
| `WINE_VERSION` | `11.0.0.0~noble-1` | WineHQ 稳定版的包版本号 |
| `APT_MIRROR` | 空 | 构建时用的 Ubuntu 镜像源，例如 `http://mirrors.tuna.tsinghua.edu.cn/ubuntu`（要用 http） |
| `VNC_PASSWORD` | 必填 | noVNC 控制密码，VNC 协议只取前 8 个字符 |
| `VNC_VIEW_PASSWORD` | 空 | noVNC 只读密码 |
| `NOVNC_BIND` / `NOVNC_PORT` | `127.0.0.1` / `6082` | noVNC 在宿主机上的监听地址和端口；和 life115-docker 的 6080 错开 |
| `HOST_DATA_DIR` | `./data` | 和客户端交换文件的宿主机目录，挂载到 `/data`（客户端里的 `Z:\data`） |
| `V2RAY_ENABLED` | `false` | 代理开关，见 [v2ray 代理](#v2ray-代理) |
| `V2RAY_VERSION` / `V2RAY_SHA256` | `5.53.0` / 对应的值 | v2ray-core 版本；也可以把 `v2ray-linux-64.zip` 放进 `vendor/` |
| `SCREEN_GEOMETRY` | `1600x900x24` | 虚拟显示器分辨率；Wine 虚拟桌面跟着它走 |
| `TZ` | `Asia/Shanghai` | 时区 |

## 安全

- noVNC 默认只监听 `127.0.0.1`。VNC 密码只有前 8 位有效，**不要把端口直接暴露到公网**；远程访问用 SSH 隧道，或者放到带认证和 TLS 的反向代理后面。
- 客户端容器以非 root 运行，去掉了全部 capability，开了 `no-new-privileges`。
- Chromium 自带的沙箱在 Wine 里起不来，客户端用 `--no-sandbox` 运行，由容器本身充当隔离边界。Wine 本身也不是安全边界：客户端能读写容器里 uid 1000 能访问的一切，包括 `/data`。
- 网络容器的权限和 life115-docker 相同：`NET_ADMIN` 设置防火墙规则，`SETUID`/`SETGID` 降权运行 v2ray，文件系统只读。
- 登录状态保存在 `pikpak-config` 卷里。能操作这台机器 Docker 的人都能用这个 PikPak 账号，请控制好 Docker 权限。
- 如果 OpenList / JITList 也登录了同一个 PikPak 账号，留意两边会不会互相挤下线（未验证）。

## 测试情况

### 已验证

v2ray 代理（2026-10-06，v2ray 5.53.0，`scripts/test-v2ray.sh` 全部通过）：

- 客户端的 TCP 连接全部经过节点；PikPak 的域名由节点解析，客户端这边的解析结果不影响去向。
- 访问内网地址直连，DNS 正常，UDP 被拒绝。
- 节点连不上、v2ray 停止（配置文件不见了）时客户端断网，不会退回直连；恢复后几秒内自动恢复联网。`ppctl.sh restart v2ray` 能重新加载配置。

客户端（2026-10-06 用 PikPak 2.15.2、Wine 11.0 在 Docker Desktop（WSL2，amd64）上测试）：

（构建完成后补充）

### 已知限制

- **没有命令行上传**，见 [和客户端交换文件](#和客户端交换文件)。
- **每个运行 JS 的 Electron 进程固定多占约 256 MB 内存。** V8 引擎为它的"沙箱"预留 1 TB 地址空间；Wine 对每 4 GB 地址空间维护 1 MB 的页属性表，预留时会把整张表写一遍，于是主进程和渲染进程各有约 256 MB 全零、但已经占用的内存。这是 Wine 的实现方式（到 Wine 11.19 仍然如此），客户端和镜像这边绕不开。宿主机有 swap 时，这些页从不再被访问，会被优先换出。
- **客户端不能自动升级。** 它的升级方式是下载新安装包再运行，而安装包是 32 位程序，镜像里没有 32 位 Wine。升级请按 [升级客户端](#升级客户端) 重新构建镜像。

### 待验证

| 项目 | 怎么确认 |
|---|---|
| 登录后的上传、下载 | 登录后从 `Z:\data` 上传一个文件，再下载到 `Z:\data` |
| 断网、重启客户端后能否续传 | 传大文件时 `ppctl.sh restart`，或者断开网络再恢复 |
| 长时间运行是否稳定 | 连续运行 72 小时，观察内存和是否掉线 |
| 提示升级时的表现 | 官方发新版后，看客户端会不会弹窗卡住 |
| 大文件和长文件名 | 传一个超过 4 GB 的文件，以及文件名很长、目录很深的文件 |

## 升级客户端

1. 下载新的安装包，算出 sha256，改 `.env` 里的 `PIKPAK_SHA256`；或者直接把新安装包放进 `vendor/`（目录里只放一个 `.exe`）。
2. 重新构建并启动：

   ```bash
   docker compose up -d --build
   ```

3. 登录状态在卷里，升级后不用重新登录。

升级 Wine 的步骤相同：改 `WINE_VERSION`，重新构建。Wine 版本变了以后，第一次启动会自动更新 Wine 环境，多花十几秒。升级 v2ray：改 `V2RAY_VERSION` 和 `V2RAY_SHA256`，然后重新构建。

## 目录结构

```
Dockerfile                 客户端镜像（两阶段：解出客户端 → 运行环境）
docker-compose.yml
.env.example
build/
  apt-stub.sh              用空包顶替用不到的依赖
  install-pikpak.sh        从安装包里解出客户端，调用 pe-realign.py
  pe-realign.py            把 exe/dll 重排成按页对齐
  install-wine.sh          安装 64 位 Wine，去掉调试信息
net/                       网络容器镜像（和 life115-docker 相同）
  Dockerfile
  pikpak-net               入口：设置透明代理规则、守护 v2ray、健康检查
v2ray/
  v2ray.example.json       节点配置示例；复制成 v2ray.json 使用（不提交）
rootfs/                    复制进镜像的文件
  etc/supervisor/pikpak.conf
  usr/local/bin/           entrypoint.sh、run-*（各进程启动脚本）、pikpak-status、pikpak-screenshot
  usr/local/lib/pikpak/common.sh
scripts/                   在宿主机上执行
  ppctl.sh                 状态、截图、重启、日志
  lib.sh
  test-v2ray.sh            v2ray 代理的端到端测试
vendor/                    可选：放本地的 official_PikPak.exe 和 v2ray-linux-64.zip
```
