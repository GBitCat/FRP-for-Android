# Android service testing

`FrpcServiceIntegrationTest` covers the first-start request race, foreground
service start/stop, Android Keystore encryption and blank-request rejection.

To test the foreground service lifecycle, connect only the selected test device
and run the following command from `flutter_app/`.

```bash
ANDROID_SERIAL=<serial> tool/run_android_lifecycle_tests.sh
```

Before a production release, run the suite on Android 15 (API 35), Android 16
(API 36), and Android 17 (API 37). Record the device build fingerprint and
test report for each run under `build/reports/androidTests/connected/`.

The ARM64 endpoint tests exercise the embedded frpc. Start a dedicated,
loopback-only frps with an empty token and run the echo provider on the same
host with Python 3.10 or later. Use the pinned Linux frpc for the provider.

```sh
python3 scripts/fixtures/socks5_echo_provider.py /path/to/frpc 14565
```

Forward that frps port to the ARM64 test device and pass both fixture arguments
to the instrumentation runner. The service test authenticates against the
provider, checks TCP and UDP echo, then repeats after restoring an encrypted
runtime configuration.

```sh
adb reverse tcp:35682 tcp:14565
adb shell am instrument -w -r \
  -e endpointAuthFrpsPort 35682 -e endpointEchoFrpsPort 35682 \
  -e class com.frp.frp_app.FrpcEndpointAuthIntegrationTest \
  com.frp.frp_app.debug.test/androidx.test.runner.AndroidJUnitRunner
adb reverse --remove tcp:35682
```
