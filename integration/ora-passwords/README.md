# Apple Passwords local bridge

Ora runs a locally installed copy of Apple's iCloud Passwords extension in WebKit. The installer copies code only, without importing passwords or another browser's extension storage. Apple's extension handles pairing, credential selection, encrypted requests, filling, generation, saving, and verification codes.

Apple's system helper refuses a direct launch from Ora's signing identity. Ora instead uses a signed embedded service to start the genuine Google Chrome application headlessly with an isolated disposable profile. A minimal local transport extension connects to the unchanged system helper. The Apple extension in Ora and Apple's helper exchange their native protocol through private pipes and the embedded service. No browser registration, system modification, privileged installation, or listening network port is needed.

The embedded service and Ora require each other's signing identifier and signing team. The service verifies Chrome's Google signing identity before launch. Its transport extension has only native messaging permission, no website access or content scripts. The profile is private and temporary, and existing Chrome profiles and sessions are untouched. The transport never decrypts messages, stores a session key, or logs message bodies. Ora remains sandboxed. Closing the connection stops the process created for this bridge.

## Install and use

Install Google Chrome in Applications and copy a trusted installation of Apple's official extension:

```sh
scripts/install-apple-passwords.sh "$APPLE_EXTENSION_DIRECTORY"
```

The same installer is available in Settings > Passwords. It checks the public-key-derived extension identifier and rejects symlinks. This does not authenticate every file of an unpacked extension, so the source must be trusted. Vendor files are not redistributed in this repository.

Apple Passwords is the default provider. Ora opens its unlock prompt automatically after the helper connects and a browser window is ready. Unlock Apple Passwords and the Passwords menu command remain available for retrying. The extension controls its pairing prompt. Its six-digit pairing challenge has not been replaced with Touch ID. One native connection remains open across tabs and refreshes. Closing Ora ends that helper session, and Apple's own lock or reauthentication requests remain authoritative.

The unlock popup stays open when you click the browser or Apple's system code prompt. Its six code fields remain available, and returning to the popup preserves partially entered digits. Use its close button or Escape to dismiss it; the Passwords menu brings an already open popup back into focus. WebKit still manages popup closure and unloading. A minimum document height leaves room for the pairing form while WebKit sizes its native popover automatically.

The compatibility adapter supplies missing Chromium history events, normalizes optional localization arguments, and reports disabled competing autofill services. Embedded completion lists send a checked popup request to the privileged background worker, avoiding a direct action call that WebKit rejects by terminating the page process. See [WebKit action validation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIActionCocoa.mm). Ora uses WebKit's own popover lifecycle. Existing installations upgrade the adapter at the next extension startup, preserving extension storage. It preserves the vendor's credential protocol and filling code. Private pages do not receive the extension.

## Validation

```sh
TEST_RUNNER_ORA_APPLE_EXTENSION_PATH="$APPLE_EXTENSION_DIRECTORY" python scripts/test-web-styles.py
```

Headless tests exercise the shipped transport through the real signed Chrome application with a synthetic native helper. A real offscreen WebKit login field triggers the extension, forwards through Chrome, and receives and fills a synthetic username and password. Three refreshes reuse one connection and Chrome process. Tests also verify rejected extension identities, ordered responses, fragmented native packets, final replies before disconnection, private-page exclusion, and the installed vendor extension's startup. The actual Apple completion list and popup are exercised with synthetic capability replies: clicking Enable Passwords reaches the six-digit pairing form without crashing the page, startup opens that form once, and three refreshes preserve the connection. Tests check the actual popover's persistent behavior, all six input rectangles within the viewport, preservation of a synthetic partial code after focus changes and page refreshes, and no extra pairing requests. The version 2 adapter upgrade preserves vendor scripts and unrelated stored state. Pairing requests are recorded but never forwarded to Apple in these tests. Content process termination reports a retryable navigation error instead of leaving an empty page.

Signed development builds include two bounded probes:

```sh
ORA_PASSWORD_BRIDGE_PROBE=1 "$ORA_APP_PATH/Contents/MacOS/OraDev"
ORA_PASSWORD_EXTENSION_BRIDGE_PROBE=1 "$ORA_APP_PATH/Contents/MacOS/OraDev"
```

The first sends only a capabilities request through the real embedded service. The second runs Apple's actual WebKit extension through that service, with a diagnostic filter that permits only capabilities requests. Neither requests credentials, pairing, or visible windows. Both were verified with the signed, sandboxed development app and the real Apple system helper.

These checks prove the previously blocked connection and synthetic end-to-end filling. Real credential selection and the user's authentication experience still require validation after the first unlock. Do not describe the tests as proving real Apple password release or a Touch ID-only unlock.

## Other browsers examined

- [Kylmora's Keychain store](https://github.com/kylmora/kylmora/blob/main/Sources/Kylmora/Passwords/KeychainPasswordStore.swift) saves its own internet-password items and can encounter access prompts for other apps' items. This does not demonstrate seamless access to the modern Apple Passwords vault.
- [Search's password panel](https://github.com/driceroland/Search/blob/main/Sources/Search/Passwords.swift) describes importing credentials into its own Keychain items.
- [DuckDuckGo's extension connection delegate](https://github.com/duckduckgo/apple-browsers/blob/main/SharedPackages/WebExtensions/Sources/WebExtensions/Manager/WebExtensionManager%2BNativeMessaging.swift) does not implement persistent native messaging ports in the inspected revision.
- [Orion's release notes](https://orionbrowser.com/updates/orion-release-notes) document support and fixes for Apple's extension. Its implementation was not available as reusable open-source code in this investigation.

## Possible system-wide frontend

A separate menu bar app and global shortcut could reuse the local transport and fill a selected field through macOS Accessibility. This needs the user's Accessibility permission and per-app testing. An arbitrary native app may not provide a website origin or writable field, so account selection and a checked destination are necessary. Passwords are text that can be filled; passkeys require the website or app's authentication protocol and cannot be inserted as text.

The existing transport is not a system-wide autofill implementation. A shared frontend would also need its own authenticated Apple protocol client, or move the vendor background and session into the persistent service. Apple already has a [Passwords menu bar feature](https://support.apple.com/guide/passwords/menu-bar-mchldd5eb88d/mac), but that alone does not establish universal field filling.
