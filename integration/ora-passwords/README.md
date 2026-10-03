# Apple Passwords extension host

Ora uses WebKit's web extension controller to run a locally installed copy of Apple's iCloud Passwords extension. The installer copies extension code only. It does not import passwords or copy another browser's extension storage. Apple's background logic retains control of pairing, credential selection, encryption, password generation, saving, and verification codes.

The controller registers regular browser pages, tab activation and navigation events, extension action popups, host permissions, and persistent native messaging to Apple's system helper. Private pages are excluded. The helper executable and application identifier are fixed, and other native applications are rejected. Message bodies and helper diagnostic streams are never logged. Native messages are bounded, support fragmented input, and drain final replies before reporting disconnection.

## Install

Pass the directory containing the official extension's `manifest.json`:

```sh
scripts/install-apple-passwords.sh "$APPLE_EXTENSION_DIRECTORY"
```

The command compiles and runs the same installer used by Ora's settings. It checks the manifest's public-key-derived extension identifier and rejects symlinks. This identifier check does not independently authenticate every file in an unpacked extension, so the source must be a trusted installation of Apple's official extension. Vendor files are not distributed in this repository.

The compatibility adapter supplies Chromium navigation events missing from WebKit and reports Ora's disabled competing autofill services. It leaves the vendor's credential protocol and filling logic intact. The background and content scripts receive the adapter on installation.

## Validation

```sh
TEST_RUNNER_ORA_APPLE_EXTENSION_PATH="$APPLE_EXTENSION_DIRECTORY" python scripts/test-web-styles.py
```

The tests run actual WebKit offscreen, load a synthetic web extension, focus a real password field, exchange framed messages with a native helper process, and assert that both login fields are filled. Reloads reuse one native process. Separate tests start the installed Apple extension with a deliberately failing helper substitute to prove its real background reaches the bridge, without accessing credentials or requesting authentication.

A signed development build can perform a no-credential helper launch probe:

```sh
ORA_PASSWORD_HELPER_PROBE=1 "$ORA_APP_PATH/Contents/MacOS/OraDev"
```

This starts the fixed system helper but sends no messages and closes it after a bounded wait. It opens no browser windows.

## External requirement

Apple limits the iCloud Passwords native messaging helper to known browser signing identities. Loading the extension does not authorize the host. Browser registration and a subsequent macOS update may be required. See [Apple's browser registration documentation](https://github.com/apple/password-manager-resources#how-apple-uses-web-browser-extension-distribution-information).

The extension host must not be described as working with real Apple credentials until the signed host passes authorization and real credential selection is verified. The transport tests use synthetic credentials. Reusing a native connection avoids reconnecting for every page; it does not override authentication that Apple requires when releasing a credential.
