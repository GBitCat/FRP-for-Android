#!/bin/bash

# 测试脚本
echo "Running tests..."

# 运行单元测试
echo "Running unit tests..."
./gradlew test

# 运行Android测试
echo "Running Android tests..."
./gradlew connectedAndroidTest

echo "Tests completed!"
