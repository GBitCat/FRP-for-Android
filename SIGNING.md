# Release signing

Release keys must not be committed to this repository. The Android build reads
signing material from these environment variables:

- `FRP_RELEASE_STORE_FILE`
- `FRP_RELEASE_STORE_PASSWORD`
- `FRP_RELEASE_KEY_ALIAS`
- `FRP_RELEASE_KEY_PASSWORD`

The GitHub release workflow additionally expects the keystore as the
`FRP_RELEASE_KEYSTORE_BASE64` repository secret.

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
   key on supported Android versions. Older devices may require a separately
   named package and an explicit data migration.
4. Generate the new key in a protected secret manager/HSM, configure the five
   GitHub secrets above, and require review on the release environment.
5. Verify the signed artifact certificate and test upgrade installs from the
   previous production APK before publishing. The release workflow also runs
   `apksigner verify` and fails if a signed artifact was not produced.

If the leaked key was ever used for public releases, rewriting Git history is
still recommended to reduce accidental reuse, but it does not revoke copies of
the key. Rotate the production signing identity first.
