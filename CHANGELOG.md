# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
