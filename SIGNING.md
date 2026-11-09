# Signing and notarization

Public releases should be signed with a **Developer ID Application** certificate
for **Karolis dev MB**, notarized by Apple, and stapled before the final ZIP is
created. `release.sh` performs these steps and verifies Gatekeeper acceptance.
It does not publish a GitHub release or install the app.

## One-time setup on a signing Mac

1. In Xcode Settings → Apple Accounts, select the Karolis dev MB team and
   Manage Certificates. Create a Developer ID Application certificate if a
   suitable identity does not already exist. Apple may require the Account
   Holder for certificate issuance. Do not use Apple Development or Apple
   Distribution for releases outside the Mac App Store.
2. Keep the certificate **and its private key** in the user's login Keychain.
   Confirm the full identity name with `security find-identity -v -p codesigning`.
3. Set up a Keychain notarization profile. With an Apple ID app-specific
   password, the following prompts securely for the password (do not put the
   password in shell arguments):

   ```sh
   xcrun notarytool store-credentials lidlight-notary \
     --apple-id '<account-holder Apple ID>' --team-id '<company team ID>'
   ```

   An App Store Connect API key is another supported authentication method.
   Notarization credentials are separate from the signing private key. Do not
   reuse a regular Apple ID password as an app-specific password.

## Back up and use another Mac

- Export the selected Developer ID certificate **with its private key** from
  Keychain Access (My Certificates) as a password-protected `.p12`. A downloaded
  `.cer` alone does not contain the private key and cannot sign builds.
- Keep the encrypted `.p12` and its export password in the personal 1Password
  account. Use a dedicated item/document for the Karolis dev MB Developer ID
  identity. Record its team, fingerprint, and expiry there. Do not export all
  identities or put the private key, `.p12`, or credentials in this repository.
- On another trusted signing Mac, retrieve the `.p12` from 1Password, import it
  into the login Keychain, and remove the temporary export. Configure its
  notarization profile separately. The same identity can sign on multiple Macs;
  a new certificate per machine is not required.
- If releases later run in CI, retrieve credentials from the CI secret store,
  import the `.p12` into a temporary Keychain for the release job, and delete
  that Keychain afterward. Local builds do not require CI credentials.

## Build a release

```sh
export SIGNING_IDENTITY='Developer ID Application: <company name> (<team ID>)'
VERSION=1.0.2 ./release.sh --check
VERSION=1.0.2 ./release.sh
```

Use the actual identity reported by `security find-identity`. Set
`NOTARY_PROFILE` if using a different Keychain profile name. Never enable shell
tracing for credential setup.

The final `build/Lidlight.zip` contains the stapled app. `build/notarization.json`
records Apple's response, and `build/Lidlight.zip.sha256` records the checksum.
If the submission is rejected, inspect the notary log using the command printed
by the script, fix the issue, and resubmit. If the tool fails or times out, use
`xcrun notarytool history --keychain-profile lidlight-notary` to find the
submission before starting another one.

Before publishing, extract the final ZIP into a temporary directory, add a
quarantine attribute to that test copy, and check it:

```sh
test_dir=$(mktemp -d)
ditto -x -k build/Lidlight.zip "$test_dir"
xattr -w com.apple.quarantine '0081;00000000;Lidlight-release-test;' "$test_dir/Lidlight.app"
codesign --verify --strict "$test_dir/Lidlight.app"
xcrun stapler validate "$test_dir/Lidlight.app"
spctl --assess --type execute --verbose=2 "$test_dir/Lidlight.app"
```

Also test an actual browser-downloaded copy on a Mac with Gatekeeper enabled:
it should open with the normal first-launch confirmation and require no
quarantine-removal command. Check the timer, sleep restoration, notification,
and launch-at-login behavior under the new signature. Quit Lidlight gracefully
before swapping installed builds; quitting restores sleep and clears its timer.

`./build.sh`, `./build.sh --install`, and `./build.sh --zip` still make ad-hoc
local builds unless `SIGNING_IDENTITY` is set. Only a successfully completed
`release.sh` produces a verified notarized release. Older published ad-hoc
releases still need their existing quarantine workaround.

Apple documentation:

- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
