# Embedded frpc binary

The Android application embeds an XUDP-enabled `frpc` built reproducibly from
[`GBitCat/frp-xudp`](https://github.com/GBitCat/frp-xudp).

- Base release: `v0.72.0`
- Source commit: `e8731afd8a2b12765636368f762b99d121a97a26`
- Source archive SHA-256: `ee7b84935e608df805c46a81c33266517ae1596919ad5b194fe6b3378c447603`
- Source overlay: `scripts/patches/frp-android-local-endpoint.patch`
- Go toolchain: `go1.26.11`
- Build tags: `frpc,noweb`
- Embedded `frpc` SHA-256: `b753f3e4e41b0a7a319666eb216808cf912dc969d8dd18c7b42ec7c090e0e292`
- Supported ABI: `arm64-v8a`

This rebuild of `v0.72.0` propagates target EOF through the provider's legacy
SOCKS5 TCP plugin after the complete response has been copied. It retains the
stability fixes for autonomous SOCKS5 UDP sessions, visitor shutdown, XUDP relay
cleanup, and bidirectional P2P bandwidth limits. It replaces the earlier
`b93b02cc` build, which reports the same version number. Use the source commit
and binary digest to distinguish them.

The experimental Android RTSP EOF workaround has been removed. TCP traffic is
forwarded without inspecting RTSP framing or synthesizing EOF. The remote frpc
running `proxies.plugin.type = "socks5"` must also include the upstream EOF fix;
upgrading only the Android visitor cannot fix an older provider. The fix closes
the logical work stream through its wrappers, preserving sibling streams on the
shared transport. The Android overlay adds a per-launch, mutually authenticated HMAC-SHA256 handshake on the app-managed loopback SOCKS endpoints. The launch key is delivered through the child’s private standard-input pipe. The proof binds both TCP ports, visitor name, fresh nonces and the UDP frame limit reported by the local core. Ordinary visitor sockets and remote FRP traffic retain their existing wire formats.

The existing Android visitor SOCKS5 configuration and `frpc nathole discover`
CLI remain compatible. Autonomous UDP sessions still require compatible
SUDP/XUDP implementations on both frpc endpoints and
`sessionMode = "datagram"` on the provider.

The upstream release already requires Go 1.26 and includes
`golang.org/x/crypto v0.58.0`, `golang.org/x/net v0.62.0`, and
`github.com/Azure/go-ntlmssp v0.1.1`. The previous 0.71 dependency security
overlay was removed. The source preparation step applies only the local endpoint overlay. For offline verification set `FRP_SOURCE_ARCHIVE` to the pinned tarball; the same archive hash check applies.

Run `scripts/build_frpc_android.sh --check` in the project container to fetch
the hash-pinned source, rebuild the binary, and
compare it byte-for-byte with the embedded artifact. Use `--install` only when
the pinned inputs or toolchain deliberately change. `scripts/update_frpc_android.sh`
is retained as an install-mode compatibility entry point. The frpc build and
audit scripts select `GOTOOLCHAIN=go1.26.11` automatically, including in the
development image that has Go 1.26.8 installed. Go downloads the pinned
toolchain on first use; certificate-engine build pins are unchanged.

`scripts/audit_go_vulnerabilities.sh` scans both the pinned source call graph
and the final Android binary with the pinned official `govulncheck v1.7.0`.
The separate certificate-source audit keeps its own Go 1.26.8 toolchain to
match the existing certificate-library build.

The Flutter Android build is intentionally restricted to `arm64-v8a`. Do not
remove that restriction unless matching, verified Android binaries are added
for every newly supported ABI.
