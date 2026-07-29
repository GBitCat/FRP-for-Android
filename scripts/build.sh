#!/bin/bash

# 构建脚本
echo "Building FRP Android app..."

# 检查是否安装了Android SDK
if [ -z "$ANDROID_HOME" ]; then
    echo "Error: ANDROID_HOME is not set"
    exit 1
fi

# 检查是否安装了Java
if ! command -v java &> /dev/null; then
    echo "Error: Java is not installed"
    exit 1
fi

# 清理项目
echo "Cleaning project..."
./gradlew clean

# 构建debug版本
echo "Building debug APK..."
./gradlew assembleDebug

# 检查构建结果
if [ $? -eq 0 ]; then
    echo "Build successful!"
    echo "APK location: app/build/outputs/apk/debug/app-debug.apk"
else
    echo "Build failed!"
    exit 1
fi
