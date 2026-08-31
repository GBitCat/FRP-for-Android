# FRP for Android

一个基于 Flutter 的 Android frpc 客户端：在手机上运行 frpc，通过 **STCP / XTCP / XUDP** 安全访问内网设备，支持 TCP/UDP P2P、自动中继与路径恢复。

![Platform](https://img.shields.io/badge/platform-Android-green)
![Arch](https://img.shields.io/badge/arch-arm64--v8a-blue)
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
- ✅ **应用配置**：表单式编辑（协议、本地 IP/端口、secretKey、加密/压缩、fallback）+ 手动编写 TOML
- ✅ **TCP / UDP 多端口**：Form Config 支持逗号列表与端口范围（如 `22,8000-8002`），按顺序配对并展开为独立代理
- ✅ **同组多成员 / 多协议**：Form Config 为每个成员独立保留字段，同一组既可混合 XTCP、XUDP 等协议，也可添加多个相同协议
- ✅ **P2P Fallback 表单**：XTCP 可配置 STCP fallback，XUDP 可配置 SUDP fallback，并按成员名称独立配对
- ✅ **Server 配置预览**：全局段 + 该 Server 下所有启用应用配置拼接，带分组注释
- ✅ **对端配置推导**：一键生成对端 frpc 配置并复制
- ✅ **导入 / 导出**：默认脱敏 zip 保留配置结构并清空已识别的凭据赋值（分享前仍需检查自定义字段与注释）；需要迁移凭据时使用密码加密备份

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

## 🚀 快速开始

1. **下载 APK**：从 [Releases](https://github.com/GBitCat/FRP-for-Android/releases) 页面下载最新版本（`arm64-v8a`）
2. **安装并打开**：首次启动会弹出省电策略提醒，建议允许通知并取消电池优化
3. **添加 Server**：配置区 → Server → 添加你的 frps 服务器（地址、端口、token）
4. **添加应用配置**：配置区 → 应用 → 添加 STCP / XTCP / XUDP 应用（选择所属 Server、协议、对端名称、secretKey）；使用 XUDP 前请先确认全部节点均已部署兼容的 `frp-xudp`
5. **启动连接**：仪表盘 → 打开 Server 开关
6. **访问对端**：在手机上连接本地 visitor 端口（如 `127.0.0.1:39522`）即可访问对端设备

## 🛠️ 开发环境

- Flutter 3.x（stable）
- JDK 21
- Android SDK
- Git

### 构建步骤

```bash
git clone https://github.com/GBitCat/FRP-for-Android.git
cd FRP-for-Android/flutter_app

flutter pub get
flutter build apk --release
# 输出：build/app/outputs/flutter-apk/app-release.apk
```

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
│   │   │   ├── config_store.dart     # SharedPreferences 存储
│   │   │   ├── toml_generator.dart   # TOML 生成 / 预览
│   │   │   └── config_import_export.dart # 导入导出
│   │   ├── state/
│   │   │   └── app_state.dart        # 全局状态
│   │   ├── screens/                  # 仪表盘 / 配置 / 设置 / 编辑 / 日志
│   │   └── widgets/                  # 玻璃导航栏 / 毛玻璃弹窗 / 卡片
│   ├── android/app/src/main/
│   │   ├── kotlin/com/frp/frp_app/
│   │   │   ├── MainActivity.kt       # Flutter 桥接
│   │   │   ├── FrpcService.kt        # 前台服务（frpc 进程管理 / 通知）
│   │   │   └── BootReceiver.kt       # 开机自启
│   │   └── jniLibs/arm64-v8a/libfrpc.so
│   └── pubspec.yaml
└── scripts/                          # 辅助脚本
```

## 📝 使用说明

### 配置区
- **Server**：管理多个 frps 服务器连接；可命名、编辑、预览拼接配置、切换当前 Server
- **应用配置**：添加 TCP / UDP / STCP / XTCP / XUDP 或手动配置；TCP / UDP 表单可填写端口列表及范围，同组配置归为一个应用
- **导入 / 导出**：默认导出保留配置结构并清空已识别的凭据赋值；密码加密备份可安全迁移完整配置

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

### TCP / UDP 多端口（Form Config）

本地端口和远程端口都可填写逗号列表或闭区间，例如本地
`22,8000-8002` 与远程 `10022,9000-9002` 会按顺序生成 4 条代理。
两侧展开后的端口数量必须一致，每个 Form 配置最多 128 组映射。

### 同组多协议（Form Config）

`Basic Information` 中的 `Group Name` 对单协议和多协议配置始终可用；留空时会
自动采用主协议名称。单协议配置也会保存并使用该名称作为应用展示名称。
在协议下拉框中切换到新的协议后，前一个成员的表单内容会保留在协议标签中；
切回标签可继续编辑，也可移除不需要保存的成员。点击协议下拉框右侧的 `+` 可添加
另一个相同协议成员；重复协议会以 `TCP 1`、`TCP 2` 等编号区分。保存两个或更多
成员时，应用会将每个成员保存为独立配置，并使用相同的组名和组 ID 在配置列表与
仪表盘中统一展示。

### 对端配置（被访问设备 frpc）
```toml
[[proxies]]
name = "xtcp_ssh"
type = "xtcp"
localIP = "192.168.1.18"
localPort = 22
secretKey = "your_secret_key"
```

## ⚠️ 注意事项

1. **架构**：仅支持 `arm64-v8a`（绝大多数现代 Android 手机）
2. **Android 版本**：建议 Android 8.0+（API 26+）；Android 13+ 需要允许通知权限
3. **frps 端**：需在 frps 上配置对应的 stcp/xtcp 代理，且对端设备需运行 frpc 并注册相同 secretKey
4. **XUDP 全链路版本**：`frps`、XUDP proxy 端 `frpc`、XUDP visitor 端 `frpc` 必须全部使用兼容的 `GBitCat/frp-xudp`，推荐统一为当前内置的 `v0.71.0-v2`；不能只在 Android 端替换，也不要与官方 FRP 或其他 fork 混用
5. **后台驻留**：为保证长时间稳定连接，请允许通知权限、取消电池优化（应用内首次启动会引导跳转），部分国产 ROM 还需在系统设置中允许后台运行
6. **内存显示**：卡片显示的是 App 与 frpc 进程的 RSS 占用，按设备总内存计算百分比

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
