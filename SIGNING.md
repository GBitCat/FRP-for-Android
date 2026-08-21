# Release signing

Release keys must not be committed to this repository. The Android build reads
signing material from these environment variables:

- `FRP_RELEASE_STORE_FILE`
- `FRP_RELEASE_STORE_PASSWORD`
- `FRP_RELEASE_KEY_ALIAS`
- `FRP_RELEASE_KEY_PASSWORD`
- `FRP_RELEASE_CERT_SHA256`

The GitHub release workflow uses an APK Signature Scheme v3 lineage to rotate
from the compromised legacy certificate on Android 9+ while retaining upgrade
compatibility on Android 8.1 and older. Configure a protected `release`
environment with these environment secrets:

- `FRP_RELEASE_OLD_KEYSTORE_BASE64`
- `FRP_RELEASE_OLD_STORE_PASSWORD`
- `FRP_RELEASE_OLD_KEY_ALIAS`
- `FRP_RELEASE_OLD_KEY_PASSWORD`
- `FRP_RELEASE_OLD_CERT_SHA256`
- `FRP_RELEASE_KEYSTORE_BASE64`
- `FRP_RELEASE_STORE_PASSWORD`
- `FRP_RELEASE_KEY_ALIAS`
- `FRP_RELEASE_KEY_PASSWORD`
- `FRP_RELEASE_CERT_SHA256`
- `FRP_RELEASE_LINEAGE_BASE64`

The two certificate fingerprint secrets must be pinned expected values, not
values calculated from the current build. The lineage must be generated with
the old signer granting installed-data and permission capabilities to the new
signer, but without rollback capability. The workflow signs v1/v2 with the
legacy certificate for API 24–27 and v3 with the new certificate for API 28+.
Keep the `release` environment variable `FRP_SIGNING_MIGRATION_APPROVED`
unset until the migration and upgrade-install tests below are complete. The
workflow fails closed unless that environment variable is exactly `true`.

The key previously committed to this repository must be treated as compromised.
Removing it from the current tree does not remove it from Git history. Existing
installations signed with that key need an explicit migration plan (Google Play
App Signing/key upgrade or an APK signing lineage where supported) before a new
production key is used. Do not silently replace the key for an existing release.

Migration procedure:

1. Record the SHA-256 certificate fingerprint of the last trusted release and
   determine whether distribution is through Google Play or direct APK files.
2. For Google Play, request an upload-key reset if only the upload key leaked;
   request a Play App Signing key upgrade when the app-signing key leaked.
3. For direct APK distribution, keep the old key only in an isolated migration
   environment and create an APK Signature Scheme v3 signing lineage to the new
   key. Because this app supports API 24, the release APK must also carry the
   old v1/v2 signer for API 24–27; those devices cannot gain key-rotation
   protection without a separately named package and explicit data migration.
4. Generate the new key in a protected secret manager/HSM, configure the eleven
   GitHub secrets above, and require review on the release environment.
5. Verify both platform signing paths and test an upgrade install from the
   previous production APK before publishing. The release workflow checks the
   old signer for API 24–27 and the new signer for API 28–36, then fails closed
   if either pinned fingerprint differs.

If the leaked key was ever used for public releases, rewriting Git history is
still recommended to reduce accidental reuse, but it does not revoke copies of
the key. Rotate the production signing identity first.
