# TEST ONLY — NOT FOR PRODUCTION

Every file in this directory is an Android instrumentation fixture for the E1-C transport proof.
The private keys here are throwaway keys generated for local loopback test servers. They carry no
production value, must never be copied into `src/main`, a production APK or a release asset, and
must never be used as a trust anchor for anything but these tests.

| File | Contents |
| --- | --- |
| `flux-test-user-ca.crt` | PEM certificate of the test CA that the user-installed-CA gate installs into the Android user trust store. |
| `flux-test-usertrust-server.crt` | PEM chain (leaf + test CA) for the loopback HTTPS server used by the user-CA gate. |
| `flux-test-usertrust-server.pk8` | PKCS#8 DER **test** private key for that leaf. |
| `flux-test-untrusted-server.crt` | PEM self-signed leaf that no trust store ever contains, used by the invalid-certificate gate. |
| `flux-test-untrusted-server.pk8` | PKCS#8 DER **test** private key for that leaf. |

Both leaves carry `subjectAltName = DNS:localhost, IP:127.0.0.1` and `extendedKeyUsage = serverAuth`,
which is what rustls and the Android verifier require. They are RSA-2048/SHA-256 and valid until
2046 so the fixtures do not expire during the lifetime of this project.

They were produced with OpenSSL:

```
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 \
  -keyout user-ca.key -out flux-test-user-ca.crt \
  -subj "/CN=Flux TEST ONLY User CA/O=Flux Instrumentation Tests" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl req -newkey rsa:2048 -nodes -sha256 -keyout server.key -out server.csr \
  -subj "/CN=localhost/O=Flux Instrumentation Tests"
openssl x509 -req -in server.csr -CA flux-test-user-ca.crt -CAkey user-ca.key -CAcreateserial \
  -days 7300 -sha256 -out server.crt \
  -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
openssl pkcs8 -topk8 -nocrypt -in server.key -outform DER -out flux-test-usertrust-server.pk8
```

The CA private key is deliberately not kept anywhere in this repository.

## FD-01 on a non-rooted Android device

The existing `android/Build/test-transport-runtime.sh` supports two manual phases without
`adb root`, local HTTPS infrastructure or a private Miniflux installation. Both phases run
instrumentation against the loopback HTTPS fixture and the real Rust/UniFFI TLS transport.

1. Enable USB debugging, connect and authorize the phone, and ensure `adb devices` lists it.
2. **Before installing the CA**, from the Flux repository root run:
   `./android/Build/test-transport-runtime.sh --phase absent`
   This must reject the test-CA-signed endpoint; public HTTPS, hostname-mismatch and
   untrusted-certificate checks also run as part of the instrumentation package.
3. Transfer `android/app/src/androidTest/resources/flux-test-user-ca.crt` to the phone.
   In Android Settings, search for **Install a certificate** → **CA certificate** (menu names
   depend on Android manufacturer and version), choose this TEST ONLY file and explicitly
   approve the OS warning. Do not install it on your Mac or on a production server.
4. Run `./android/Build/test-transport-runtime.sh --phase present`. The same
   loopback HTTPS server must now be trusted by the Rust transport; the other TLS tests must
   continue passing.
5. **Immediately remove** `Flux TEST ONLY User CA` from Android Settings under installed
   user credentials/certificates. Do not leave the test CA trusted during ordinary phone use.

If `adb` sees multiple devices, append the serial before `--phase`.
The script deliberately does not install or remove certificates in manual mode and
refuses to run if the observed certificate state disagrees with the requested phase.
The existing root-capable automated two-phase mode remains available without `--phase`.

Record the two test outcomes and Android version under FD-01 in
`docs/FDROID_OPEN_GATES.md`. Passing only the public HTTPS check is partial evidence,
not a completed FD-01 sign-off.
