# FRP for Android

一个基于 Flutter 的 Android frpc 客户端：在手机上运行 frpc，通过 **STCP / XTCP** 安全访问内网设备（SSH、ADB 等），支持 P2P 打洞与 STCP 中继回落。

![Platform](https://img.shields.io/badge/platform-Android-green)
![Arch](https://img.shields.io/badge/arch-arm64--v8a-blue)
![License](https://img.shields.io/badge/license-MIT-orange)

## ✨ 功能特性

### 远程访问
- ✅ **STCP / XTCP 应用配置**：手机作为 visitor，安全访问对端 frpc 暴露的服务（SSH、ADB 等）
- ✅ **XTCP P2P 打洞**：NAT 打洞直连，失败自动回落 STCP 中继（`fallbackTo`）
- ✅ **分组管理**：同一应用的 stcp/xtcp 归为一组，仪表盘按应用显示连接状态

### 配置管理
- ✅ **多 Server 连接配置**：命名、8 位 ID、transport 参数（protocol / tcpMux / heartbeat / keepalive）
- ✅ **应用配置**：表单式编辑（协议、本地 IP/端口、secretKey、加密/压缩、fallback）+ 手动编写 TOML
- ✅ **Server 配置预览**：全局段 + 该 Server 下所有启用应用配置拼接，带分组注释
- ✅ **对端配置推导**：一键生成对端 frpc 配置并复制
- ✅ **导入 / 导出**：JSON + 完整 TOML 打包为 zip

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
4. **添加应用配置**：配置区 → 应用 → 添加 STCP / XTCP 应用（选择所属 Server、协议、对端名称、secretKey）
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

> `libfrpc.so` 已打包在 `android/app/src/main/jniLibs/arm64-v8a/`，无需额外下载。

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
- **应用配置**：添加 STCP / XTCP / 手动编写配置；同组配置归为一个应用（仪表盘统一显示状态）
- **导入 / 导出**：设置区可将配置导出为 `backup.zip`（JSON + 完整 TOML），也可导入恢复

### 仪表盘
- **Server 卡片**：开关启动 / 停止，显示 Active / 未启动与连接方式
- **内存卡片**：显示 App + frpc 的 RSS 占用，进度条按设备实际内存计算（RAM %）

### 设置区
- 主题模式 / 主题色、隐藏最近任务、流量统计开关、日志查看、导入导出、版本信息

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
4. **后台驻留**：为保证长时间稳定连接，请允许通知权限、取消电池优化（应用内首次启动会引导跳转），部分国产 ROM 还需在系统设置中允许后台运行
5. **内存显示**：卡片显示的是 App 与 frpc 进程的 RSS 占用，按设备总内存计算百分比

## 🤝 贡献

欢迎贡献代码与反馈 Issues！

### 贡献者
- [GBitCat](https://github.com/GBitCat)

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 🔗 相关链接

- [FRP 官方文档](https://github.com/fatedier/frp)
- [FRP Releases](https://github.com/fatedier/frp/releases)
- [Android 开发者文档](https://developer.android.com/)

## 🙏 致谢

- [FRP](https://github.com/fatedier/frp) - Fast Reverse Proxy
- [Flutter](https://flutter.dev/) - UI 框架
- UI 风格参考 [FlClash](https://github.com/chen08209/FlClash) 与 [liquid_glacier](https://github.com/osmandemiroz/liquid_glacier)

---

**⭐ 如果这个项目对你有帮助，请给个 Star 支持一下！**
