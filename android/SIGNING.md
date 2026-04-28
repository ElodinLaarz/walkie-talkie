# Release Signing Configuration

This app uses a signing configuration that falls back to debug keys when no release keystore is configured. This allows `flutter run --release` to work in development while supporting proper release signing for distribution.

## Setup for Release Builds

To sign release builds with your own keystore:

### 1. Generate a keystore

```bash
keytool -genkey -v -keystore android/keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Follow the prompts to set:
- Keystore password
- Key password
- Your name, organization, etc.

### 2. Create key.properties

Create `android/key.properties` with the following content:

```properties
storeFile=keystore.jks
storePassword=<your keystore password>
keyAlias=upload
keyPassword=<your key password>
```

**Important:** Both `keystore.jks` and `key.properties` are already in `.gitignore` and should **never** be committed to version control.

### 3. Build the release APK

```bash
flutter build apk --release
```

The APK will be signed with your release keystore.

## Fallback Behavior

If `key.properties` doesn't exist:
- Release builds fall back to debug signing
- This is fine for local testing with `flutter run --release`
- CI builds without a keystore configured will use debug signing

## CI/CD

For automated builds, you can:
1. Store the keystore and credentials as secrets in your CI system
2. Generate `key.properties` from those secrets before building
3. Or continue using debug signing for internal test builds
