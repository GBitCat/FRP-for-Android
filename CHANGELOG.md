# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-11-18

### Added

- Visitors can forward TCP and UDP through a peer's SOCKS5 service. Named port groups support per-group target IPs and on-demand or immediate connections.
- P2P configurations probe resolved STUN addresses before startup. Server settings support wire protocols v1 and v2.
- SOCKS5 logs can be filtered by configuration and port group, then exported using the active filters.

### Changed

- Updated the embedded frpc-xudp core to v0.72.0, including TCP SOCKS5 EOF handling. Update the peer providing SOCKS5 to pick up that fix.
- Target Android 17 (API 37) and retain Android 9 (API 28) support for release builds. On Android 17, starting a tunnel can request Nearby devices access for LAN peers.
- Reduced memory use when viewing long log histories and importing small configuration backups. Release builds reclaim two Dart debug files left by an in-place upgrade.

### Fixed

- Android saves the pending configuration encrypted and sends only a request ID to the service, so TOML files up to 512 KiB can start reliably. Restarting the service also prevents a previous frpc process from removing the new process's configuration file.
- Ordinary visitors that bind to a hostname can run alongside SOCKS5 listeners on separate ports.

### Security

- The Android forwarder and the embedded frpc authenticate both ends of each internal SOCKS connection with a new secret for each service start.

## [0.2.0] - 2026-09-04

### Added

- Added managed mutual-TLS certificate management backed by a dedicated Go shared library and Dart FFI.
- Added separate device identity and CA workflows for CSR generation, certificate installation, external CSR signing, CA recovery, and frps deployment bundles.
- Added Server Config identity selection and runtime resolution of private certificate paths for bidirectional verification.
- Added real frpc/frps mutual-TLS end-to-end coverage and Android API 35 instrumentation coverage in CI.

### Changed

- Made Server Config fields compact and visually consistent, with certificate identities selected from a drop-down.
- Allowed screen capture in Debug builds while retaining screenshot and recording protection in Release builds.
- Hardened the release workflow with reproducible native-library checks, isolated signing, signer lineage validation, provenance attestation, and atomic tag publication.

### Security

- Isolated release signing material from the repository and Docker mounts.
- Added sensitive filename pre-commit checks and complete-history Gitleaks CI.
- Deleted imported backup cache copies after use and removed stale backup cache artifacts at startup.
- Expanded runtime log redaction and removed free-form manual-TOML comments from redacted backups.
- Added screenshot protection, hidden server tokens by default, and a sensitive clipboard with 60-second automatic clearing.
- Restricted the foreground-service notification PendingIntent to an explicit app component.

## [0.1.9] - 2026-09-01

### Added

- Added compact `visitor.FormConfig` for grouped XTCP/XUDP visitor configuration.
- Added multiple protocols and multiple bind ports/ranges in one logical group.
- Added automatic STCP fallback generation for XTCP and SUDP fallback generation for XUDP.
- Added peer-side proxy configuration derivation with visitor-matched default `localPort` values.
- Added persistent Docker development caches for Pub, Gradle, development HOME, and the debug signing key.

### Changed

- Moved shared name, server name, bind address, secret key, encryption, and compression fields to the group level.
- Appended protocol suffixes to generated names and port suffixes when a protocol contains multiple ports.
- Moved the peer-configuration button above the configuration preview.
- Renamed the guided configuration entry to `visitor.FormConfig`.

### Fixed

- Fixed non-encrypted backup round trips losing visitor structure; redacted exports now preserve configuration structure while clearing recognized credentials only.
- Fixed fallback naming for multi-port configurations and names whose base text contains a protocol token.
- Prevented duplicate/invalid port lists and mixing disabled port `-1` with concrete ports.
- Preserved generated groups safely when editing and prevented unsupported legacy form protocols from being overwritten.

## [0.1.0] - 2024-01-01

### Added
- Initial release
- Minimum viable product (MVP) with basic FRP client functionality
