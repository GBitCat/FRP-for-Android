# Release signing

Release keys must never be committed to this repository, copied into a
development container, or stored in a persistent development cache. Gradle
release builds are always unsigned and reject both `FRP_RELEASE_*` signing
variables and Android's injected signing properties; only the isolated workflow
below is authorized to produce a signed APK. A
separately reviewed offline recovery procedure must apply the same APK policy,
signer fingerprint, lineage, capability, and signature-scheme checks.

## Production policy

The key previously committed to this repository is compromised. Rewriting Git
history cannot revoke downloaded copies, so the normal GitHub release workflow
never loads or uses that key.

Production releases use these controls:

- the complete reusable CI gate runs on the exact release commit;
- only the repository default branch may be released;
- the unsigned build job has read-only permissions, disables persisted checkout
  credentials, and has no signing secrets;
- the signing job has no checkout and does not execute repository or dependency
  build code;
- the exact two-certificate lineage and its old-signer capabilities are checked
  in a separate step before any keystore or key password is exposed;
- signing secrets exist only in the single signing step and temporary key files
  are deleted by a shell trap before publication;
- after signing and attestation, the workflow atomically creates a new release
  tag at the audited commit and verifies its exact SHA again after publication;
  an existing tag is never reused or moved;
- production APKs have `minSdk 28` and are signed only by the rotated signer
  with an APK Signature Scheme v3 lineage; v1 and v2 are intentionally disabled
  because neither scheme can carry the proof-of-rotation without loading the
  compromised oldest signer;
- the signed APK receives a GitHub/Sigstore SLSA provenance attestation, and its
  SHA-256 checksum plus attestation bundle are published with the release.

Configure the protected GitHub `release` environment with:

- `FRP_RELEASE_KEYSTORE_BASE64`
- `FRP_RELEASE_STORE_PASSWORD`
- `FRP_RELEASE_KEY_ALIAS`
- `FRP_RELEASE_KEY_PASSWORD`
- `FRP_RELEASE_CERT_SHA256`
- `FRP_RELEASE_LINEAGE_BASE64`

`FRP_RELEASE_CERT_SHA256` must be the independently pinned SHA-256 fingerprint
of the new certificate. The workflow also pins the compromised previous
certificate fingerprint and requires an exact two-certificate lineage. The old
signer must retain only the installed-data and permission capabilities; shared
UID, rollback, and authenticator capabilities must all be disabled. Keep the
`FRP_SIGNING_MIGRATION_APPROVED` environment variable unset until upgrade
installation from the last trusted release has passed on API 28 and every
supported newer Android version. The workflow fails closed unless its value is
exactly `true`.

## Android 7–8.1

APK Signature Scheme v3 key rotation is unavailable on API 24–27. Those
installations cannot be protected from a leaked legacy signer while retaining
same-package direct-APK upgrades. The production workflow therefore declares
API 24–27 end-of-support and does not produce an old-key compatibility APK.
Debug and local unsigned builds may still use the Flutter minimum SDK for
development, but they are not production artifacts.

If continued API 24–27 distribution is a product requirement, use a new
`applicationId` and an explicit, reviewed data migration. Do not put the old
private key back into GitHub Actions. A one-time offline migration artifact
signed with the old key remains exposed to forgery and is not considered a
security fix.

For Google Play distribution, use Play App Signing key upgrade when the
app-signing key leaked, or an upload-key reset when only the upload key leaked.
Require release-environment reviewers and branch protection independently of
the repository workflow.

If any current signing secret is exposed, revoke or rotate it before publishing
again and follow the hosting provider's sensitive-history removal process.
Deleting a file from the current tree is never sufficient.

If publication fails after reserving the tag, the workflow deletes it only when
no release exists and the ref still points to the audited commit. If a release
was created, or the ref changed, the workflow deliberately leaves both in place:
inspect and remove the partial release/tag manually before retrying the same
version. This avoids automated cleanup deleting a concurrently modified ref.
