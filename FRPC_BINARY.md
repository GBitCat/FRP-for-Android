# Embedded frpc binary

The Android application embeds an XUDP-enabled `frpc` built reproducibly from
[`GBitCat/frp-xudp`](https://github.com/GBitCat/frp-xudp).

- Base release: `v0.71.0-v2`
- Source commit: `305ab02e14034d4152dd6780d9879718e96ad4f5`
- Source archive SHA-256: `e658accc2ab0f239b12b3a7528c49d12efcb0377789ce3e7eb1f50c40225d16a`
- Security overlay: `scripts/patches/frp-xudp-v0.71.0-v2-go-security.patch`
- Go toolchain: `go1.26.8`
- Build tags: `frpc,noweb`
- Embedded `frpc` SHA-256: `1a5b096cac3241c490f89fa19121f59224ece4b93b30c48f6d078845b6805cb1`
- Supported ABI: `arm64-v8a`

The security overlay raises the source module to Go 1.26 and pins
`golang.org/x/crypto v0.56.0`, `golang.org/x/net v0.57.0`,
`github.com/Azure/go-ntlmssp v0.1.1`, and their required transitive updates.

Run `scripts/build_frpc_android.sh --check` in the project container to fetch
the hash-pinned source, apply the reviewed overlay, rebuild the binary, and
compare it byte-for-byte with the embedded artifact. Use `--install` only when
the pinned inputs or toolchain deliberately change. `scripts/update_frpc_android.sh`
is retained as an install-mode compatibility entry point.

`scripts/audit_go_vulnerabilities.sh` scans both the patched source call graph
and the final Android binary with the pinned official `govulncheck v1.7.0`.

The Flutter Android build is intentionally restricted to `arm64-v8a`. Do not
remove that restriction unless matching, verified Android binaries are added
for every newly supported ABI.
