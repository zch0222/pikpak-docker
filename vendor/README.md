构建镜像时会优先使用这个目录里的安装包，不再从网上下载：

- PikPak 的 Windows 安装包 `official_PikPak.exe`（官网下载的原名），客户端镜像用。目录里有多个 `.exe` 时只用第一个，建议只放一个。
- v2ray 的 `v2ray-linux-64.zip`（文件名保持 GitHub 发布页上的原名），网络容器镜像用。版本要和 `.env` 里的 `V2RAY_VERSION` 一致。

这两种文件都不会提交到 git。
