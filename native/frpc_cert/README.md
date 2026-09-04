# libfrpc_cert

`libfrpc_cert.so` 是证书管理区使用的 Go `c-shared` 引擎。Flutter 通过 Dart FFI
调用固定的 JSON ABI，Go 直接在 Android `noBackupFilesDir/tls` 下写入密钥、CSR、证书和元数据。

## 职责边界

- `Certificates`：在设备内生成客户端私钥和 CSR，安装签发证书与可信服务端 CA。
- `Authorities`：创建密码加密的 CA、恢复 CA、签发本机或外部 CSR，并在高级模式生成 frps 证书。
- Dart 负责表单、文件选择与密码加密导出；Go 负责密钥生成、X.509 校验、签发和私有文件落盘。

ABI 版本为 `1`，导出符号为：

- `FrpCertAbiVersion()`
- `FrpCertInvoke(request_json)`
- `FrpCertFree(response)`

## 存储与安全

客户端私钥和本地生成的服务端私钥权限为 `0600`，管理目录权限为 `0700`。CA 私钥使用
PBKDF2-HMAC-SHA256（600,000 次）派生的 AES-256-GCM 密钥加密，证书 SHA-256 指纹参与
附加认证数据。写入使用同目录临时文件、`fsync` 和原子重命名，并拒绝符号链接目录与越界 ID。

CA 恢复包在已加密的 CA 私钥外，再使用 Android `BackupCipher` 加密整个归档。`.frpca` 与
`.frptls` 都采用 `FRPB v1` 加密封装（PBKDF2 + AES-256-GCM），不会把服务端私钥以明文
留在 Android 公共存储。当前实现没有远程在线 CA、CRL/OCSP、自动续期或 Android Keystore
内不可导出的 TLS 客户端私钥。

## 在 frps 主机解包 `.frptls`

仓库同时提供独立的 Go/Linux 工具。它只从标准输入读取口令，安全校验 ZIP 条目，并将私钥
以 `0600`、目标目录以 `0700` 写入；目标目录已存在时会拒绝覆盖。

```bash
cd native/frpc_cert
../../scripts/build_frpc_cert_tool.sh

read -rsp 'Bundle password: ' FRPC_BUNDLE_PASSWORD; echo
printf '%s\n' "$FRPC_BUNDLE_PASSWORD" | \
  ../../build/tools/linux-amd64/frpc-cert-tool extract-frptls \
    -in ./server.frptls -out ./frps-tls
unset FRPC_BUNDLE_PASSWORD
```

解包后的 `server-ca.crt` 是签发 `server.crt` 的 CA，应部署给 frpc；
`trusted-client-ca.crt` 则是 frps 用来验证客户端证书的 CA 集合。只有明确采用同一个 CA
签发服务端和客户端证书时，两者才包含同一 CA。先核对 `frps-tls/frps-tls.toml` 中的路径，
再将其合并到实际 `frps.toml`。不要在命令行参数中传口令，也不要把解包目录提交到版本库。

## 测试与构建

```bash
go test -race ./...
../../scripts/build_frpc_cert_tool.sh
../../scripts/build_frpc_cert_android.sh
```

构建脚本使用 Android NDK 生成 ARM64 真正的共享对象，并校验导出符号、无 `INTERP` 以及
16 KiB ELF LOAD 段对齐，输出到
`flutter_app/android/app/src/main/jniLibs/arm64-v8a/libfrpc_cert.so`。
