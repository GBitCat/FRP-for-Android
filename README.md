# FRP for Android

一个基于 Flutter 的 Android frpc 客户端：在手机上运行 frpc，通过 **STCP / XTCP / XUDP** 安全访问内网设备，支持 TCP/UDP P2P、自动中继与路径恢复。

![Platform](https://img.shields.io/badge/platform-Android-green)
![Arch](https://img.shields.io/badge/arch-arm64--v8a-blue)
[![Release](https://img.shields.io/github/v/release/GBitCat/FRP-for-Android?display_name=tag)](https://github.com/GBitCat/FRP-for-Android/releases/latest)
![License](https://img.shields.io/badge/license-MIT-orange)

## ✨ 功能特性

### 远程访问
- ✅ **STCP / XTCP 应用配置**：手机作为 visitor，安全访问对端 frpc 暴露的服务（SSH、ADB 等）
- ✅ **XTCP P2P 打洞**：NAT 打洞直连，失败自动回落 STCP 中继（`fallbackTo`）
- ✅ **XUDP P2P**：基于 frp-xudp 的 QUIC DATAGRAM，P2P 失败时自动 Relay，并周期恢复直连
- ✅ **分组管理**：同一应用的 stcp/xtcp 归为一组，仪表盘按应用显示连接状态

> [!IMPORTANT]
> **XUDP 不能只替换 Android 端。** 同一条 XUDP 链路中的 `frps`、提供服务的
> `frpc` 和作为 visitor 的 `frpc`（本应用）必须全部部署兼容的
> [`GBitCat/frp-xudp`](https://github.com/GBitCat/frp-xudp) 版本，建议保持完全相同的
> Release。不要将官方 `fatedier/frp`、其他 fork 或不同版本与 XUDP 节点混用。
> 当前 APK 内置版本为 `v0.71.0-v2`，其余节点应优先使用同一版本。

### 配置管理
- ✅ **多 Server 连接配置**：命名、8 位 ID、transport 参数（protocol / tcpMux / heartbeat / keepalive）
- ✅ **应用配置**：组级 `visitor.FormConfig`（公共 name、serverName、secretKey、加密/压缩）+ 手动编写 TOML
- ✅ **P2P 多端口**：XTCP / XUDP 各自支持逗号列表与端口范围，一个端口展开为一个 visitor
- ✅ **同组多协议**：同一 `visitor.FormConfig` 可同时添加 XTCP 与 XUDP，公共字段只需填写一次
- ✅ **自动 P2P Fallback**：开启 Fallback 后，XTCP 自动派生 STCP，XUDP 自动派生 SUDP
- ✅ **Server 配置预览**：全局段 + 该 Server 下所有启用应用配置拼接，带分组注释
- ✅ **对端配置推导**：一键生成对端 frpc 配置并复制，`localPort` 默认匹配 visitor 端口
- ✅ **导入 / 导出**：默认脱敏 zip 保留配置结构、清空已识别的凭据赋值并移除 Manual TOML 注释（分享前仍需检查自定义字段值）；需要迁移凭据时使用密码加密备份

### 双向 TLS 与证书管理
- ✅ **设备证书**：私钥只在 Android 应用私有目录生成，支持导出 CSR、安装签发后的客户端证书与可信服务端 CA
- ✅ **CA 独立管理**：CA 与设备证书分区展示；CA 私钥使用密码加密保存，可为本机身份或其他设备提交的 CSR 签发证书
- ✅ **frps 证书**：高级本地部署模式可生成带 DNS / IP SAN 的服务端证书和私钥，并导出密码加密的部署包
- ✅ **安全恢复**：CA 可导出双层密码保护的恢复包，恢复后可以继续为新设备签发证书
- ✅ **Server Config 联动**：Server Config 只保存设备身份 ID，启动时从证书库重新解析 Bidirectional Verification 私有路径

### 仪表盘
- ✅ **Server 卡片**：一键开关、连接状态（Active / 未启动）、连接方式（P2P / 中继）
- ✅ **网络与内存**：IPv4 / IPv6、App + frpc 真实 RSS 占用（按设备总内存显示 RAM %）
- ✅ **应用状态列表**：按应用分组显示 stcp/xtcp 连接状态

### 后台驻留
- ✅ **前台服务 + 常驻通知**：后台持续运行，不易被系统回收
- ✅ **开机自启**：设备重启后自动恢复连接
- ✅ **进程重建自动恢复 frpc**：无需手动再次启动
- ✅ **省电策略提醒**：首次启动弹窗提醒，一键跳转取消电池优化

### 界面
- ✅ **玻璃 / 折射风格 UI**：透明玻璃导航栏、毛玻璃弹窗
- ✅ **主题**：浅色 / 深色 / 跟随系统 + 7 种主题色，持久化保存
- ✅ **日志查看**：frpc 运行日志实时查看
- ✅ **敏感信息保护**：Release 版禁止系统截图/录屏（Debug 版便于测试而允许捕获）；Token 与 Secret Key 默认隐藏；配置与日志剪贴板 60 秒自动清理

## 🚀 快速开始

1. **下载 APK**：从 [Releases](https://github.com/GBitCat/FRP-for-Android/releases) 页面下载最新版本（`arm64-v8a`）及对应的 `app-release.apk.sha256`
2. **安装并打开**：首次启动会弹出省电策略提醒，建议允许通知并取消电池优化
3. **添加 Server**：配置区 → Server → 添加你的 frps 服务器（地址、端口、token）
4. **添加应用配置**：配置区 → `visitor.FormConfig` 添加 XTCP / XUDP visitor，或使用 Manual Config 编写其他 proxy / visitor；使用 XUDP 前请先确认全部节点均已部署兼容的 `frp-xudp`
5. **可选启用双向 TLS**：在证书管理区创建或恢复 CA、生成设备身份，并在 Server Config 的 `Bidirectional Verification` 中选择身份
6. **启动连接**：仪表盘 → 打开 Server 开关
7. **访问对端**：在手机上连接本地 visitor 端口（如 `127.0.0.1:39522`）即可访问对端设备

下载完成后可在保存 APK 与摘要文件的目录执行校验：

```bash
sha256sum --check app-release.apk.sha256
```

### 双向 TLS 快速流程

1. 在 **证书管理 → Authorities** 创建 CA，或用恢复包恢复已有 CA。
2. 在 **Certificates** 生成本机身份与 CSR，使用受信任 CA 签发客户端证书后，将证书安装回该身份。
3. 为 frps 的域名或 IP 生成服务端证书部署包；frps 使用其中的 `server.crt`、`server.key`，并将 `trustedCaFile` 指向 `trusted-client-ca.crt`。
4. 将部署包中的 `server-ca.crt` 安装为设备身份的可信服务端 CA。存在多个客户端 CA 时，把允许接入的客户端 CA 合并到 frps 的 `trusted-client-ca.crt` PEM bundle。
5. 回到 **Server Config → Bidirectional Verification**，从下拉栏选择已安装完成的设备身份。

## 🛠️ 开发环境

- Flutter 3.x（stable）
- Go 1.26.8 (the native build scripts require this exact version)
- JDK 21
- Android SDK + NDK r28c
- Git

### Docker 开发环境（持久缓存）

项目根目录的 `docker-dev.sh` 与 `compose.yaml` 使用同一组 Docker 命名卷保存 Pub、
Gradle 和开发 HOME 缓存。
开发容器停止或由 `docker compose run --rm` 删除后缓存仍会保留，且不会产生常驻的
CPU / 内存占用；Android debug keystore 也保存在开发 HOME 卷中，因此后续 Debug APK
可以保留数据覆盖安装。首次使用可执行：

```bash
./scripts/install-hooks.sh
./docker-dev.sh flutter pub get
./docker-dev.sh flutter test
./docker-dev.sh /workspace/scripts/build.sh
```

默认通过宿主机 `127.0.0.1:8118` 代理下载依赖；可通过 `HTTP_PROXY`、
`HTTPS_PROXY` 和 `NO_PROXY` 覆盖。安装了 Compose 插件时也可以使用
`LOCAL_UID=1000 LOCAL_GID=1000 docker compose run --rm dev <命令>`。
`docker compose down` 不会删除缓存，只有显式执行 `docker compose down -v` 才会删除
三个命名卷。

### 构建步骤

```bash
git clone https://github.com/GBitCat/FRP-for-Android.git
cd FRP-for-Android
./scripts/install-hooks.sh
./docker-dev.sh /workspace/scripts/build_frpc_cert_android.sh
./docker-dev.sh flutter build apk --release
# 输出：flutter_app/build/app/outputs/flutter-apk/app-release.apk
```

发布密钥、密码、签名 lineage、用户备份和截图必须存放在 Git checkout 与所有 Docker
挂载/构建上下文之外。仓库钩子会拦截敏感文件名，GitHub Actions 会对完整历史运行固定
版本且校验摘要的 Gitleaks。详见 [SECURITY.md](SECURITY.md) 与 [SIGNING.md](SIGNING.md)。

> `libfrpc.so` 来自 `GBitCat/frp-xudp` 的校验发布资产，已打包在
> `android/app/src/main/jniLibs/arm64-v8a/`，无需额外下载。当前 APK 仅支持
> `arm64-v8a`；版本、摘要和更新流程见 [FRPC_BINARY.md](FRPC_BINARY.md)。

## 📁 项目结构

```
FRP-for-Android/
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart                 # 入口
│   │   ├── theme.dart                # 主题（模式 / 主题色）
│   │   ├── models/                   # 数据模型
│   │   │   ├── frp_config.dart       # 应用配置
│   │   │   ├── server_config.dart    # Server 配置
│   │   │   └── connection_status.dart
│   │   ├── services/
│   │   │   ├── frp_engine.dart       # MethodChannel 桥接
│   │   │   ├── config_store.dart     # Keystore 加密配置存储
│   │   │   ├── config_domain_service.dart # 分组、命名与 Fallback 派生
│   │   │   ├── port_mapping_parser.dart # 多端口列表 / 范围解析
│   │   │   ├── toml_generator.dart   # TOML 生成 / 预览
│   │   │   ├── config_import_export.dart # ZIP / JSON 导入导出
│   │   │   ├── backup_crypto.dart    # 密码加密备份桥接
│   │   │   ├── sensitive_file_cache.dart # 敏感临时文件定向清理
│   │   │   ├── secure_clipboard.dart # 敏感剪贴板与定时清理桥接
│   │   │   └── certificates/          # Dart FFI 桥接与证书数据模型
│   │   ├── state/
│   │   │   └── app_state.dart        # 全局状态
│   │   ├── screens/                  # 仪表盘 / 配置 / 证书管理 / 设置 / 编辑 / 日志
│   │   └── widgets/                  # 玻璃导航栏 / 毛玻璃弹窗 / 卡片
│   ├── android/app/src/main/
│   │   ├── kotlin/com/frp/frp_app/
│   │   │   ├── MainActivity.kt       # Flutter 桥接
│   │   │   ├── FrpcService.kt        # 前台服务（frpc 进程管理 / 通知）
│   │   │   ├── BootReceiver.kt       # 开机自启
│   │   │   ├── SecureStringCodec.kt  # Android Keystore 配置加密
│   │   │   └── BackupCipher.kt       # PBKDF2 + AES-256-GCM 备份加密
│   │   └── jniLibs/arm64-v8a/
│   │       ├── libfrpc.so            # frpc ARM64 可执行核心
│   │       └── libfrpc_cert.so       # Go c-shared 证书引擎
│   └── pubspec.yaml
├── native/frpc_cert/                 # CA / CSR / X.509 签发与私有文件存储
├── docker-dev.sh / compose.yaml      # 持久缓存 Docker 开发环境
└── scripts/                          # 构建、测试与部署脚本
```

## 📝 使用说明

### 配置区
- **Server**：管理多个 frps 服务器连接；可命名、编辑、预览拼接配置、切换当前 Server
- **应用配置**：`visitor.FormConfig` 快速创建同组 XTCP / XUDP visitor（可自动派生 STCP / SUDP），其他场景可使用 Manual Config
- **导入 / 导出**：默认导出保留配置结构并清空已识别的凭据赋值；密码加密备份可安全迁移完整配置

### 证书管理区
- **Certificates**：生成本机私钥与 CSR，安装客户端证书和可信服务端 CA，并应用到 Server Config
- **Authorities**：创建或恢复 CA、签发外部 CSR、生成 frps 服务端证书；CA 私钥不会以明文落盘
- **跨设备签发**：其他设备在本地保留私钥并提交 CSR，本应用只返回签发证书；无需传输对方私钥

### 仪表盘
- **Server 卡片**：开关启动 / 停止，显示 Active / 未启动与连接方式
- **内存卡片**：显示 App + frpc 的 RSS 占用，进度条按设备实际内存计算（RAM %）

### 设置区
- 主题模式 / 主题色、隐藏最近任务、日志查看、导入导出、版本信息

## 🔧 配置示例

### Server 配置（frps 连接）
```toml
serverAddr = "frp.example.com"
serverPort = 7000
auth.token = "your_token"

transport.protocol = "tcp"
transport.tcpMux = true
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90
transport.tcpMuxKeepaliveInterval = 30
```

### 应用配置（手机端 visitor）
```toml
[[visitors]]
name = "cachyos-xtcp-ssh"
type = "xtcp"
serverName = "xtcp_ssh"
secretKey = "your_secret_key"
bindPort = 39522
fallbackTo = "cachyos-stcp-ssh"
fallbackTimeoutMs = 3000
```

### 同组多协议与多端口（visitor.FormConfig）

`Basic Information` 中的 `Group Name` 保持独立；留空时采用公共 `Name`。在下面的
组级表单中，`Name`、`Server Name`、`Bind Address` 和 `Secret Key` 均只填写一次。
通过协议下拉框与 `+` 分别添加 XTCP、XUDP 后，每个协议会显示自己的
`Bind Port(s)` 输入框，支持逗号列表和闭区间（如 `39001,39100-39102`），每个协议
最多展开 128 个端口。

生成名称时始终追加协议后缀，例如 `Application-Name` 生成
`Application-Name-xtcp`。当同一协议填写多个端口时，`name` 与 `serverName` 还会追加
对应端口号，例如 `Application-Name-xtcp-39001`。开启 `Fallback` 后不再填写额外回落
字段：应用直接从每条 XTCP / XUDP 配置派生对应的 STCP / SUDP 配置。
`Derive Peer Config` 按钮位于配置详情上方；生成的每条对端 proxy 默认使用对应 visitor
填写的 `Bind Port` 作为 `localPort`，Fallback proxy 复用其主协议端口。请按对端真实服务
监听端口修改该值。

### 对端配置（被访问设备 frpc）
```toml
[[proxies]]
name = "xtcp_ssh"
type = "xtcp"
localIP = "192.168.1.18"
localPort = 39522 # 默认匹配 visitor bindPort，可按实际服务端口修改
secretKey = "your_secret_key"
```

## ⚠️ 注意事项

1. **架构**：仅支持 `arm64-v8a`（绝大多数现代 Android 手机）
2. **Android 版本**：正式 Release APK 支持 Android 9.0+（API 28+）；Android 13+ 需要允许通知权限
3. **frps 端**：需在 frps 上配置对应的 stcp/xtcp 代理，且对端设备需运行 frpc 并注册相同 secretKey
4. **XUDP 全链路版本**：`frps`、XUDP proxy 端 `frpc`、XUDP visitor 端 `frpc` 必须全部使用兼容的 `GBitCat/frp-xudp`，推荐统一为当前内置的 `v0.71.0-v2`；不能只在 Android 端替换，也不要与官方 FRP 或其他 fork 混用
5. **后台驻留**：为保证长时间稳定连接，请允许通知权限、取消电池优化（应用内首次启动会引导跳转），部分国产 ROM 还需在系统设置中允许后台运行
6. **内存显示**：卡片显示的是 App 与 frpc 进程的 RSS 占用，按设备总内存计算百分比
7. **敏感画面**：Release 版启用 Android `FLAG_SECURE`，系统截图、录屏与最近任务缩略图会被阻止或隐藏；Debug 版明确不启用，便于开发测试
8. **旧版签名限制**：Android 8.1 及更早版本不支持当前 APK 使用的 v3 密钥轮换，因此不在正式 Release APK 的支持范围内；只从官方 Releases 安装并核对 SHA-256
9. **CA 恢复**：删除 CA 前先导出恢复包并妥善保存两层密码；当前版本不提供在线 CA、证书吊销列表或自动轮换

## 🤝 贡献

欢迎贡献代码与反馈 Issues！

### 贡献者
- [GBitCat](https://github.com/GBitCat)

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 🔗 相关链接

- [FRP 官方文档](https://github.com/fatedier/frp)
- [FRP Releases](https://github.com/fatedier/frp/releases)
- [GBitCat/frp-xudp](https://github.com/GBitCat/frp-xudp)
- [Android 开发者文档](https://developer.android.com/)

## 🙏 致谢

- [FRP](https://github.com/fatedier/frp) - Fast Reverse Proxy
- [Flutter](https://flutter.dev/) - UI 框架
- UI 风格参考 [FlClash](https://github.com/chen08209/FlClash) 与 [liquid_glacier](https://github.com/osmandemiroz/liquid_glacier)

---

**⭐ 如果这个项目对你有帮助，请给个 Star 支持一下！**
