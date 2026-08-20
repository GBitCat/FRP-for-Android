# Android service testing

`FrpcServiceIntegrationTest` covers the first-start request race, foreground
service start/stop, Android Keystore encryption and blank-request rejection.

For Android 15/16 lifecycle certification, connect only the approved test
device and run:

```bash
ANDROID_SERIAL=<serial> tool/run_android_15_16_tests.sh
```

The runner refuses API levels other than 35 and 36, so an older device cannot
accidentally be reported as an Android 15/16 pass. Run the suite once on API 35
and once on API 36 before a production release. Record the device build
fingerprint and test report under `build/reports/androidTests/connected/`.
