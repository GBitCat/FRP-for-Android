# Security Policy

## Supported versions

Only the latest published `0.1.x` release receives security fixes.

## Report a vulnerability privately

Do not open a public issue or attach credentials, backups, logs, screenshots,
server addresses, or proof-of-concept secrets to a public discussion.

Use GitHub's private vulnerability reporting form:

https://github.com/GBitCat/FRP-for-Android/security/advisories/new

Include the affected version, impact, reproduction steps, and a minimal
redacted proof of concept. The maintainer will acknowledge the report and
coordinate disclosure through the private advisory.

## User security guidance

- Install APKs only from this repository's Releases page and verify the
  published SHA-256 file.
- Use unique FRP tokens and secret keys. Rotate them if they were ever included
  in a public issue, log, screenshot, or unencrypted backup.
- A redacted export clears recognized credential fields but remains intended
  for review and sharing. Use the password-encrypted backup for a complete
  private migration.
- Peer configurations and logs may contain infrastructure details. Their
  clipboard entries are marked sensitive and automatically cleared after 60
  seconds.
- Android 8.1 and older cannot use APK Signature Scheme v3 key rotation. Direct
  APK upgrades on those versions remain tied to the legacy release certificate;
  see [SIGNING.md](SIGNING.md).

## Developer controls

- Build and test through the Docker environment documented in `README.md`.
- Keep production signing keys, passwords, lineages, `.env` files, user
  backups, and screenshots outside the repository and outside mounted build
  contexts.
- Run `./scripts/install-hooks.sh` after cloning. The pre-commit hook rejects
  sensitive filenames, and GitHub Actions scans complete history with a pinned
  Gitleaks release.
- Never paste real configurations or logs into tests. Use unmistakably fake
  examples such as `example.com` and `test-only-secret`.

Repository history was rewritten after a legacy signing key was committed.
History removal reduces accidental discovery but cannot revoke copies already
downloaded; the legacy key must continue to be treated as compromised.
