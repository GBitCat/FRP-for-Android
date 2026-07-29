#!/bin/bash

# FRP Android - 模拟器测试脚本
# 使用方法: ./scripts/test_on_emulator.sh

echo "=========================================="
echo "FRP Android - 模拟器测试"
echo "=========================================="

# 设置Android SDK路径
export ANDROID_HOME=~/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/platform-tools

# 检查ADB
if [ ! -f "$ANDROID_HOME/platform-tools/adb" ]; then
    echo "错误: 未找到ADB，请检查Android SDK安装"
    exit 1
fi

# 启动ADB服务
echo "启动ADB服务..."
$ANDROID_HOME/platform-tools/adb kill-server
sleep 1
$ANDROID_HOME/platform-tools/adb start-server

# 连接到模拟器
echo "连接到模拟器 127.0.0.1:16512..."
$ANDROID_HOME/platform-tools/adb connect 127.0.0.1:16512

# 检查设备
echo ""
echo "检查已连接设备..."
$ANDROID_HOME/platform-tools/adb devices

# 构建APK
echo ""
echo "构建APK..."
if [ -f "gradlew" ]; then
    ./gradlew assembleDebug
else
    echo "警告: 未找到gradlew，请先生成Gradle Wrapper"
    echo "运行: gradle wrapper"
    exit 1
fi

# 检查APK是否生成
APK_PATH="app/build/outputs/apk/debug/app-debug.apk"
if [ ! -f "$APK_PATH" ]; then
    echo "错误: APK构建失败"
    exit 1
fi

# 安装APK
echo ""
echo "安装APK到模拟器..."
$ANDROID_HOME/platform-tools/adb install -r $APK_PATH

# 启动应用
echo ""
echo "启动应用..."
$ANDROID_HOME/platform-tools/adb shell am start -n com.frp.app/.MainActivity

echo ""
echo "=========================================="
echo "测试完成!"
echo "=========================================="
echo ""
echo "注意事项:"
echo "1. 如果frpc二进制文件是占位符，连接功能将无法使用"
echo "2. 请下载真正的frpc二进制文件替换 app/src/main/assets/frpc"
echo "3. 下载地址: https://github.com/fatedier/frp/releases"
echo "=========================================="
