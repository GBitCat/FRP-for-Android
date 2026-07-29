#!/bin/bash

# 部署脚本
echo "Deploying FRP Android app..."

# 检查是否连接了Android设备
if ! adb devices | grep -q "device$"; then
    echo "Error: No Android device connected"
    exit 1
fi

# 构建APK
echo "Building APK..."
./gradlew assembleDebug

# 安装APK
echo "Installing APK..."
adb install -r app/build/outputs/apk/debug/app-debug.apk

# 启动应用
echo "Starting app..."
adb shell am start -n com.frp.app/.MainActivity

echo "Deployment completed!"
