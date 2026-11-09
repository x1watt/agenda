# agenda app

The Flutter front end: Linux desktop and Android phone. See the repository README for what the
whole thing does and `../docs/format.md` for the data it reads.

## Builds

    flutter build linux --release     # then tool/install-linux.sh
    flutter build apk --release --target-platform android-arm64
    adb install -r build/app/outputs/flutter-apk/app-release.apk

Android package `x1watt.agenda`. Release signing expects an `android/key.properties` with
`storeFile`, `storePassword`, `keyAlias` and `keyPassword`; that file and the keystore stay out of
this repository.

On a machine with little memory, serialize heavy builds (two concurrent Gradle or Flutter builds
can freeze a 16 GB box).
