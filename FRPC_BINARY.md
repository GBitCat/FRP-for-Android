# Embedded frpc binary

The Android applications embed the XUDP-enabled `frpc` build published by
[`GBitCat/frp-xudp`](https://github.com/GBitCat/frp-xudp).

- Release: `v0.71.0-v2`
- Asset: `frp_0.71.0_android_arm64.tar.gz`
- Asset SHA-256: `c52b58e745f2ee86617fd8e1a8b54815eff13d394523173b24b2004e6e943c10`
- Embedded `frpc` SHA-256: `2255feb0991463816e7f17f5beae61d0ba006d700f991ff8758add70311e78f0`
- Supported ABI: `arm64-v8a`

Run `bash scripts/update_frpc_android.sh` inside the `FA-dev` container to
repeat the verified download and update the Flutter Android application. The script
rejects an asset or extracted binary whose digest does not match this record.

The Flutter Android build is intentionally restricted to `arm64-v8a`. Do not
remove that restriction unless matching, verified Android binaries are added
for every newly supported ABI.
