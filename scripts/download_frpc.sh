#!/bin/bash

# FRP版本
FRP_VERSION="0.51.3"
# 下载URL
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_arm64.tar.gz"
# 下载目录
DOWNLOAD_DIR="./downloads"
# 输出目录
OUTPUT_DIR="./app/src/main/assets"

# 创建目录
mkdir -p $DOWNLOAD_DIR
mkdir -p $OUTPUT_DIR

echo "Downloading frpc v${FRP_VERSION}..."

# 下载frpc
curl -L $DOWNLOAD_URL -o $DOWNLOAD_DIR/frp.tar.gz

# 解压
echo "Extracting frpc..."
tar -xzf $DOWNLOAD_DIR/frp.tar.gz -C $DOWNLOAD_DIR

# 复制frpc到assets目录
echo "Copying frpc to assets..."
cp $DOWNLOAD_DIR/frp_${FRP_VERSION}_linux_arm64/frpc $OUTPUT_DIR/frpc

# 设置可执行权限
chmod +x $OUTPUT_DIR/frpc

# 清理
echo "Cleaning up..."
rm -rf $DOWNLOAD_DIR

echo "Done! frpc has been downloaded to $OUTPUT_DIR/frpc"
