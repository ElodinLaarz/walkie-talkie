# Release Signing Configuration

This app requires proper signing configuration for release builds. **Release builds will fail at configure time if no signing material is provided.** This prevents accidentally shipping debug-signed builds to production.

## Setup for Release Builds

To sign release builds with your own keystore, use **either** the file-based or environment-based approach:

### Option 1: File-based Configuration (Local Development)

#### 1. Generate a keystore

```bash
keytool -genkey -v -keystore android/keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Follow the prompts to set:
- Keystore password
- Key password
- Your name, organization, etc.

#### 2. Create key.properties

Create `key.properties` in the **project root** (not in `android/`) with:

```properties
storeFile=android/keystore.jks
storePassword=<your keystore password>
keyAlias=upload
keyPassword=<your key password>
```

**Important:** Both `keystore.jks` and `key.properties` are in `.gitignore` and must **never** be committed to version control.

#### 3. Build the release AAB

```bash
flutter build appbundle --release
```

### Option 2: Environment Variables (CI/CD)

Set the following environment variables before building:

- `KEYSTORE_PATH` — absolute path to the keystore file
- `KEYSTORE_PASSWORD` — keystore password
- `KEY_ALIAS` — key alias
- `KEY_PASSWORD` — key password

Environment variables take precedence over `key.properties`.

#### Example GitHub Actions Setup

1. **Create secrets** in your repository settings:
   - `KEYSTORE_BASE64` — base64-encoded keystore file (`base64 -w 0 < keystore.jks`)
   - `KEYSTORE_PASSWORD`
   - `KEY_ALIAS`
   - `KEY_PASSWORD`

2. **Use the release workflow** (`.github/workflows/release.yml`):
   - Triggered by version tags (`v*`) or manual dispatch
   - Decodes `KEYSTORE_BASE64` to a temporary file
   - Sets environment variables from secrets
   - Builds and uploads the signed AAB

## Fail-Fast Behavior

If a **release** build is requested without signing configuration:
- The Gradle configure phase will fail immediately with a clear error message
- This prevents debug-signed APKs/AABs from being accidentally uploaded to Play Store

Debug builds continue to work normally and do not require signing configuration.

## Troubleshooting

**Error: "Release signing configuration is missing"**
- For local builds: create `key.properties` as described above
- For CI builds: ensure all four environment variables are set
- Verify the keystore file exists at the specified path

**CI build fails with "KEYSTORE_BASE64 secret is not set"**
- Add the required secrets to your repository settings (Settings → Secrets → Actions)
- See "Option 2: Environment Variables" above for the full list
