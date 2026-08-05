# FRP Android

一个简单易用的Android FRP客户端应用，用于在Android设备上运行frpc。

![Platform](https://img.shields.io/badge/platform-Android-green)
![API](https://img.shields.io/badge/API-33%2B-blue)
![License](https://img.shields.io/badge/license-MIT-orange)

## ✨ 功能特性

### 核心功能
- ✅ **配置管理**：添加、编辑、删除FRP代理配置
- ✅ **一键连接**：快速启动/停止FRP连接
- ✅ **状态监控**：实时显示连接状态
- ✅ **日志查看**：查看frpc运行日志，支持实时滚动和过滤
- ✅ **后台服务**：支持应用在后台持续运行
- ✅ **通知控制**：通过通知栏快速控制连接

### 高级功能
- ✅ **配置导入/导出**：支持JSON格式导入导出配置
- ✅ **流量统计**：实时监控上传/下载速度和总流量
- ✅ **开机自启**：设备启动时自动运行FRP
- ✅ **多配置切换**：快速切换不同的代理配置

## 🚀 快速开始

### 1. 下载APK
从 [Releases](https://github.com/gbitcat/FRP-M/releases) 页面下载最新版本的APK文件。

### 2. 安装应用
```bash
adb install frp-android.apk
```

### 3. 配置FRP
1. 打开应用
2. 点击 "+" 添加新配置
3. 填写服务器信息
4. 保存配置

### 4. 启动连接
1. 在配置列表中选择要使用的配置
2. 点击 "Start" 按钮
3. 等待连接成功

## 🛠️ 开发环境

### 必备工具
- Android Studio Hedgehog 或更新版本
- Android SDK 34
- Java 17
- Git

### 构建步骤

1. **克隆项目**
```bash
git clone https://github.com/gbitcat/FRP-M.git
cd FRP-M
```

2. **下载frpc二进制文件**
```bash
./scripts/download_frpc.sh
```

3. **构建APK**
```bash
./scripts/build.sh
```

4. **部署到设备**
```bash
./scripts/deploy.sh
```

## 📁 项目结构

```
FRP-M/
├── app/
│   └── src/main/java/com/frp/app/
│       ├── data/           # 数据层
│       │   ├── FrpConfig.kt          # 配置数据模型
│       │   ├── FrpConfigDao.kt       # 数据访问对象
│       │   ├── FrpConfigRepository.kt # 数据仓库
│       │   ├── AppDatabase.kt        # 数据库
│       │   ├── ConfigGenerator.kt    # 配置文件生成器
│       │   └── ConfigImportExport.kt # 配置导入/导出
│       ├── manager/        # 管理器
│       │   ├── FrpManager.kt         # frpc进程管理
│       │   ├── LogManager.kt         # 日志管理
│       │   └── TrafficStats.kt       # 流量统计
│       ├── service/        # 服务
│       │   └── FrpService.kt         # 前台服务
│       ├── viewmodel/      # ViewModel
│       │   └── MainViewModel.kt      # 主ViewModel
│       ├── receiver/       # 广播接收器
│       │   └── BootReceiver.kt       # 开机自启
│       ├── ui/theme/       # UI主题
│       │   ├── Color.kt              # 颜色定义
│       │   ├── Theme.kt              # 主题配置
│       │   └── Type.kt               # 字体样式
│       └── *.kt            # Activity文件
├── scripts/                # 构建脚本
│   ├── build.sh            # 构建脚本
│   ├── deploy.sh           # 部署脚本
│   ├── download_frpc.sh    # 下载frpc脚本
│   └── test.sh             # 测试脚本
└── *.md                    # 项目文档
```

## 📝 使用说明

### 添加配置
1. 点击主界面右下角的 "+" 按钮
2. 填写配置信息：
   - **配置名称**：给配置起一个名字
   - **服务器地址**：FRP服务器的域名或IP
   - **服务器端口**：通常是7000
   - **认证令牌**：服务器配置的token
   - **本地IP**：通常是127.0.0.1
   - **本地端口**：本地服务的端口
   - **远程端口**：在服务器上暴露的端口
   - **协议类型**：TCP、UDP、HTTP等
3. 点击 "Save" 保存配置

### 导入配置
1. 点击右上角菜单按钮
2. 选择 "Import Config"
3. 选择JSON格式的配置文件
4. 配置将自动导入

### 导出配置
1. 点击右上角菜单按钮
2. 选择 "Export Config"
3. 选择分享方式发送配置文件

### 查看日志
1. 点击右上角的日志图标
2. 可以按级别过滤日志
3. 支持自动滚动和手动滚动
4. 可以复制日志到剪贴板

### 查看流量统计
1. 点击右上角的流量图标
2. 查看实时上传/下载速度
3. 查看总流量统计
4. 查看连接数统计

## 🔧 配置示例

### TCP转发
```json
{
  "name": "SSH Server",
  "serverAddr": "frp.example.com",
  "serverPort": 7000,
  "token": "your_token_here",
  "localIp": "127.0.0.1",
  "localPort": 22,
  "remotePort": 6000,
  "protocol": "tcp"
}
```

### HTTP转发
```json
{
  "name": "Web Server",
  "serverAddr": "frp.example.com",
  "serverPort": 7000,
  "token": "your_token_here",
  "localIp": "127.0.0.1",
  "localPort": 80,
  "remotePort": 8080,
  "protocol": "http"
}
```

## ⚠️ 注意事项

1. **Android版本**：需要Android 13 (API 33) 或更高版本
2. **frpc二进制文件**：需要单独下载或编译arm64版本的frpc
3. **权限要求**：需要网络、前台服务、通知等权限
4. **电池优化**：建议用户关闭电池优化以确保后台运行

## 🤝 贡献

欢迎贡献代码！请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 了解详情。

### 贡献者
- [gbitcat](https://github.com/gbitcat)

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 🔗 相关链接

- [FRP官方文档](https://github.com/fatedier/frp)
- [FRP Releases](https://github.com/fatedier/frp/releases)
- [Android开发者文档](https://developer.android.com/)

## 📞 联系方式

- GitHub: [gbitcat](https://github.com/gbitcat)

## 🙏 致谢

感谢以下开源项目：
- [FRP](https://github.com/fatedier/frp) - Fast Reverse Proxy
- [Jetpack Compose](https://developer.android.com/jetpack/compose) - Android UI框架
- [Room](https://developer.android.com/training/data-storage/room) - 数据库框架
- [Hilt](https://dagger.dev/hilt/) - 依赖注入框架

---

**⭐ 如果这个项目对你有帮助，请给个Star支持一下！**
