# GitHub DMG signing and notarization setup

This document describes the one-time setup required for the GitHub Actions macOS
installer workflow to sign, notarize, staple, verify, and upload the DevHQ DMG.

Pull-request builds use ad-hoc signing. Manual workflow runs and trusted `v*`
tag builds use the secrets below to produce a distributable DMG trusted by
Gatekeeper.

## Required Apple account setup

You need:

- An active Apple Developer Program membership.
- A **Developer ID Application** certificate.
- An Apple ID app-specific password for notarization.
- Your Apple Developer Team ID.

You do **not** need to submit DevHQ through the Mac App Store for direct DMG
distribution. Developer ID signing plus notarization is the outside-the-App-Store
path.

## 1. Create a certificate signing request

Create a CSR and private key locally:

```sh
openssl req -new -newkey rsa:2048 -nodes \
  -keyout DeveloperIDApplication.key \
  -out DeveloperIDApplication.csr \
  -subj "/emailAddress=YOUR_APPLE_ID_EMAIL,CN=YOUR NAME,C=US"
```

Keep `DeveloperIDApplication.key` private. You will need it to create the `.p12`
file after Apple issues the certificate.

## 2. Create the Developer ID Application certificate

1. Open the Apple Developer portal.
2. Go to **Certificates, Identifiers & Profiles**.
3. Create a new certificate.
4. Select **Developer ID Application**.
5. Upload `DeveloperIDApplication.csr`.
6. Download the issued `.cer` file.

Convert the `.cer` and private key into a `.p12`:

```sh
openssl x509 -inform DER \
  -in developerID_application.cer \
  -out developerID_application.pem

openssl pkcs12 -export \
  -inkey DeveloperIDApplication.key \
  -in developerID_application.pem \
  -out DeveloperIDApplication.p12
```

Use a strong password when prompted. This password becomes the
`APPLE_CERTIFICATE_PASSWORD` GitHub secret.

## 3. Find the signing identity

Import the `.p12` into your local login keychain, then run:

```sh
security find-identity -v -p codesigning
```

Find the line for the Developer ID Application certificate. The identity should
look like:

```text
Developer ID Application: Your Name (TEAMID)
```

Use that full string for the `APPLE_SIGN_IDENTITY` GitHub secret.

## 4. Create an Apple app-specific password

App-specific passwords are managed from Apple ID account settings, not App Store
Connect.

1. Open <https://account.apple.com/account/manage>.
2. Go to **Sign-In and Security**.
3. Open **App-Specific Passwords**.
4. Generate a password named `DevHQ GitHub Notarization`.
5. Copy it immediately. Apple only shows it once.

Use the generated value for the `APPLE_APP_SPECIFIC_PASSWORD` GitHub secret.

## 5. Find the Apple Team ID

The Team ID is a 10-character identifier, for example:

```text
AB12C3D4E5
```

You can find it in the Apple Developer account membership details, or in the
Developer ID Application identity shown by `security find-identity` inside the
parentheses.

Use this value for the `APPLE_TEAM_ID` GitHub secret.

## 6. Configure GitHub secrets

The workflow reads these repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded `DeveloperIDApplication.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting/creating the `.p12` |
| `APPLE_KEYCHAIN_PASSWORD` | Random temporary CI keychain password |
| `APPLE_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple account email address |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password from Apple ID settings |

Use the GitHub CLI to set them without pasting secret values into chat or commit
history.

```sh
# Path to the .p12 created above.
P12_PATH="/path/to/DeveloperIDApplication.p12"

base64 -i "$P12_PATH" | gh secret set APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64

gh secret set APPLE_CERTIFICATE_PASSWORD
gh secret set APPLE_KEYCHAIN_PASSWORD
gh secret set APPLE_SIGN_IDENTITY
gh secret set APPLE_ID
gh secret set APPLE_TEAM_ID
gh secret set APPLE_APP_SPECIFIC_PASSWORD
```

When prompted, enter:

- `APPLE_CERTIFICATE_PASSWORD`: the `.p12` password.
- `APPLE_KEYCHAIN_PASSWORD`: any strong random password for CI keychain use.
- `APPLE_SIGN_IDENTITY`: the full Developer ID Application identity string.
- `APPLE_ID`: your Apple account email address.
- `APPLE_TEAM_ID`: your Apple Developer Team ID.
- `APPLE_APP_SPECIFIC_PASSWORD`: the generated app-specific password.

## 7. Run the workflow

Run the workflow manually to produce a signed test artifact, or push a `v*` tag
to produce and publish a signed release. Pull requests exercise the same
packaging path without access to the Developer ID identity.

When the secrets are configured, the workflow will:

1. Import the Developer ID Application certificate into a temporary keychain.
2. Sign every nested Mach-O file and the app bundle with hardened runtime and a
   secure timestamp.
3. Build the DMG.
4. Sign the DMG.
5. Submit the DMG to Apple notarization.
6. Staple the notarization ticket to the DMG.
7. Verify the DMG and app signature.
8. Upload the finished DMG artifact.

## Troubleshooting

### The workflow says it is using ad-hoc signing

`APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` is missing or empty. Set all secrets
listed above.

### Notarization returns `Invalid`

Open the **Notarize and staple DMG** step. The workflow prints Apple's notary log
when notarization fails. The log names the rejected file and reason.

### Stapling fails with `Could not find base64 encoded ticket`

Apple did not accept the notarization submission. Fix the `Invalid` reason in the
notary log, rerun the workflow, and staple only after the status is `Accepted`.

### GitHub pull requests from forks are not signed

GitHub does not expose repository secrets to forked pull request workflows. Those
runs will fall back to ad-hoc signing.
