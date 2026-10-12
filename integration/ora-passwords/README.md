# Apple Passwords local bridge

Ora runs a locally installed copy of Apple's iCloud Passwords extension in WebKit. The installer copies code only, without importing passwords or another browser's extension storage. Apple's extension handles pairing, credential selection, encrypted requests, filling, generation, saving, and verification codes.

Apple's system helper refuses a direct launch from Ora's signing identity. Ora uses its signed local service to start the genuine Google Chrome application headlessly with an isolated private profile. A minimal transport extension connects to the unchanged system helper. The Apple extension in Ora and Apple's helper exchange their native protocol through private pipes. A per-user LaunchAgent keeps this connection alive across browser exits. No browser registration, privileged installation, or listening network port is needed.

Ora and the service require each other's signing identifier and signing team. The service verifies Chrome's Google signing identity before launch. Its transport extension has only native messaging permission, no website access or content scripts. The profile is private and temporary; existing Chrome profiles and sessions are untouched. The transport never decrypts messages or logs message bodies. A separate session owner retains only the authenticated channel key and transaction identifier in memory, with a strict schema that excludes passwords and pairing codes. The same native port stays open when Ora exits. A new extension worker restores the vendor cipher through the signed interprocess connection. Ora remains sandboxed. Reboot, helper termination, Lock Apple Passwords, or Apple's expiration messages clear the pairing. No session key is written to disk.

## Install and use

Install Google Chrome in Applications and copy a trusted installation of Apple's official extension:

```sh
scripts/install-apple-passwords.sh "$APPLE_EXTENSION_DIRECTORY"
```

Install the background service once at the permanent signed app path:

```sh
python scripts/install-password-session-agent.py "$ORA_APP_PATH"
```

The installer verifies the app signature and registers a user LaunchAgent. Updating an already registered agent preserves its live process. The launch configuration records the executable path, never session data. Run this step after installing a development build.

The extension installer is available in Settings > Passwords. It checks the public-key-derived extension identifier and rejects symlinks. This does not authenticate every file of an unpacked extension, so the source must be trusted. Vendor files are not redistributed in this repository.

Apple Passwords is the default provider. A genuinely new session opens Apple's pairing prompt after the helper connects and a browser window is ready. Ora restores a retained session without a new pairing popup or startup authentication prompt. Apple still authorizes credential release, including Touch ID when required. Quit fully closes Ora; its private background session remains available for the next launch. Apple's lock and reauthentication requests remain authoritative. Unlock Apple Passwords and the Passwords menu command remain available for retrying. Lock Apple Passwords explicitly clears pairing and stops its helper process.

Automatic code entry is an optional fallback, off by default. Settings > Passwords and the live setting `passwords.apple.automaticPairing` control it. With Accessibility permission, the signed service asks macOS to authenticate the user, reads static code labels only from its own signed Apple helper process, and submits through the vendor popup. It refuses ambiguous dialogs and preserves digits already entered by the user. It does not bypass Apple's handshake or credential authorization. Headless tests cover permission denial, cancellation, process ownership, label parsing, and actual vendor form submission with a synthetic code. The real Accessibility permission and biometric flow have not been exercised headlessly.

The unlock popup stays open when you click the browser or Apple's system code prompt. Its six code fields remain available, and returning to the popup preserves partially entered digits. Use its close button or Escape to dismiss it; the Passwords menu brings an already open popup back into focus. WebKit still manages popup closure and unloading. A minimum document height leaves room for the pairing form while WebKit sizes its native popover automatically. The native popup follows Ora's effective appearance, including system appearance changes. Its code inputs and background use neutral light and dark palettes. Apple's separate system-owned dialog remains controlled by macOS.

The compatibility adapter supplies missing Chromium history events, normalizes optional localization arguments, and reports disabled competing autofill services. Embedded completion lists send a checked popup request to the privileged background worker, avoiding a direct action call that WebKit rejects by terminating the page process. See [WebKit action validation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIActionCocoa.mm). Ora uses WebKit's own popover lifecycle. Existing installations upgrade the adapter at the next extension startup, preserving extension storage. It preserves the vendor's credential protocol and filling code. Private pages do not receive the extension.

## Validation

### Native passkeys in Ora

WebKit owns the complete Web Authentication request and presents macOS authentication in Ora's window. Ora leaves the built-in creation, assertion, availability, conditional mediation, and extension interfaces intact. The custom JavaScript passkey shim, separate passkey service endpoints, and Chrome passkey transport have been removed. Password filling still uses the existing Apple Passwords extension and retained session; it is a separate integration.

Native access to existing Apple passkeys requires Apple's managed browser passkey entitlement in the signed Ora executable and a matching approved provisioning profile. Settings > Passwords reports whether this build has that signing authorization. A build without the capability does not advertise authorization through another browser. WebKit remains responsible for its native behavior and supported external authenticators.

To build with a profile already approved for the exact development bundle identifier:

```sh
ORA_REQUIRE_NATIVE_PASSKEYS=1 \
ORA_PASSKEY_PROVISIONING_PROFILE="$PASSKEY_PROFILE" \
ORA_DEVELOPMENT_TEAM="$SIGNING_TEAM" scripts/build-dev.sh
```

The build verifies the profile's capability, signing team, exact bundle identifier, expiration, and identifier before selecting the native passkey signing configuration. The main app receives that profile; the separate password service keeps its own signing configuration. Required native builds stop before compiling when no profile is supplied. The local development configuration remains available for development without the restricted capability, and Settings reports that Apple passkey access is unavailable in that build.

The separate browser review configuration uses the permanent, brand-neutral identifier
`io.github.kevinjohncutler.browser`, with a matching `.PasswordBridge` service identifier:

```sh
ORA_DEVELOPMENT_TEAM="$SIGNING_TEAM" scripts/build-browser-review.sh
```

It keeps Ora Dev as the working display name and writes to a separate review build directory.
It does not install or launch the app. The existing development build, sandbox container,
and retained password session keep their current identity. Switching the installed app
requires a deliberate migration of its data and service registration. The development
installer rejects this review identifier. An approved profile for the permanent identifier
can be supplied through the same native-passkey environment options; its profile is checked
against the permanent identifier rather than the legacy development identifier.

An installation can require native authorization before replacing the existing app:

```sh
python -S scripts/install-dev.py "$BUILT_ORA_APP" --require-native-passkeys
```

The installer checks the signed app's entitlement and embedded profile before changing the installation. Every app that declares the restricted capability must pass the profile checks, even without the required flag. macOS and Xcode remain responsible for validating Apple's signing approval. The checks do not manufacture or request an entitlement.

The signed app's headless diagnostic calls only WebKit's native availability function and reads its own signing metadata:

```sh
ORA_PASSKEY_CAPABILITY_PROBE=1 "$ORA_APP_PATH/Contents/MacOS/OraDev"
```

It never invokes a credential request, launches Chrome, reads a stored passkey, or changes password pairing. It exits successfully only when native signing authorization and native platform availability are both present. A missing capability is a failed native-access check, not a passing test.

Headless tests run actual Ora pages with production browser scripts, verify that WebKit authentication functions remain native across refreshes, and verify a pre-aborted native request. Account-backed admission tests use a test-only credential blocker so a website cannot initiate real authentication during the authorized email-only probe. These checks do not prove physical Touch ID or real Apple credential release. Native access is incomplete until an approved signed build passes the availability diagnostic and actual authentication is verified.

```sh
TEST_RUNNER_ORA_APPLE_EXTENSION_PATH="$APPLE_EXTENSION_DIRECTORY" python scripts/test-web-styles.py
```

Headless tests exercise the shipped transport through the real signed Chrome application with a synthetic native helper. A real offscreen WebKit login field triggers the extension, forwards through Chrome, and receives and fills a synthetic username and password. Three refreshes reuse one connection and Chrome process. Tests also verify rejected extension identities, ordered responses, fragmented native packets, final replies before disconnection, private-page exclusion, and the installed vendor extension's startup. The actual Apple completion list and popup are exercised with synthetic capability replies: clicking Enable Passwords reaches the six-digit pairing form without crashing the page, startup opens that form once, and three refreshes preserve the connection. Tests check the actual popover's persistent behavior, all six input rectangles within the viewport, preservation of a synthetic partial code after focus changes and page refreshes, and no extra pairing requests. Adapter version 5 regenerates only its worker wrapper and popup assets, preserving the original vendor source, completion script, and unrelated stored state. Pairing requests are recorded but never forwarded to Apple in these tests. Content process termination reports a retryable navigation error instead of leaving an empty page.

Further headless tests replace the actual vendor WebKit worker and decrypt a synthetic helper reply with the restored channel. They verify no resumed-session startup popup, native port reuse across detached app clients, explicit locking, server expiration, and dark/light/dark switching without losing entered digits.

Signed development builds include bounded probes:

```sh
ORA_PASSWORD_BRIDGE_PROBE=1 "$ORA_APP_PATH/Contents/MacOS/OraDev"
ORA_PASSWORD_EXTENSION_BRIDGE_PROBE=1 "$ORA_APP_PATH/Contents/MacOS/OraDev"
```

The first sends only a capabilities request through the real signed background service. The second runs Apple's actual WebKit extension through that service, with a diagnostic filter that permits only capabilities requests. Neither requests credentials, pairing, or visible windows. Both were verified with the signed, sandboxed development app and the real Apple system helper.

The process-reopen diagnostic runs two separate signed, sandboxed app processes against an initially unpaired background agent:

```sh
ORA_PASSWORD_SESSION_REOPEN_PROBE=store "$ORA_APP_PATH/Contents/MacOS/OraDev"
ORA_PASSWORD_SESSION_REOPEN_PROBE=resume "$ORA_APP_PATH/Contents/MacOS/OraDev"
```

It stores only a synthetic channel in the service, verifies that the second process receives it through the same live Chrome process, and clears the synthetic state before exiting. Only capabilities requests reach Apple's real helper. The first stage refuses to replace an existing paired session. It prints process metadata, never keys or credentials. Both stages passed with the signed development app.

These checks prove the previously blocked connection and synthetic end-to-end filling. Real credential selection and the user's authentication experience still require validation after the first unlock. Do not describe the tests as proving real Apple password release or a Touch ID-only unlock.

## Other browsers examined

### Native passkeys and signing access

The Chrome authentication window is an external-browser workaround, not native Ora integration. Its presentation does not meet the intended browser experience. The external passkey broker has been removed. Native WebKit authentication is now the only production passkey path, subject to the signing requirements below.

Chrome calls Apple's AuthenticationServices controller with the website's challenge and origin and supplies its own window as the presentation anchor. The operating system selects the Apple passkey, verifies the user, and returns a signed assertion. Chrome's signed application has `com.apple.developer.web-browser.public-key-credential`. Safari uses Apple's system signing permissions, including `com.apple.authentication-services.allow-authentication-request-any-rpid`; Safari does not need Chrome's public entitlement key. Browser permission granted by a user and the browser's signing authorization are separate requirements.

Relevant primary sources and implementations:

- [Apple's browser passkey integration](https://developer.apple.com/documentation/authenticationservices/authenticating-people-by-using-passkeys-in-browser-apps) shows a native assertion controller and a presentation anchor supplied by the browser. [Apple's entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential) specifies a managed capability approved for the developer account. Adding the key to a local entitlement file does not provide the approved provisioning profile.
- [DuckDuckGo's production macOS entitlements](https://github.com/duckduckgo/apple-browsers/blob/main/macOS/DuckDuckGo/DuckDuckGo.entitlements) include the browser passkey entitlement. Its [debug entitlements](https://github.com/duckduckgo/apple-browsers/blob/main/macOS/DuckDuckGo/DuckDuckGoDebug.entitlements) omit it. This distinction matters when evaluating locally built open-source browsers.
- [cmux's native coordinator](https://github.com/manaflow-ai/cmux/blob/main/Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/WebAuthn/BrowserWebAuthnSupport.swift) creates Apple platform assertion requests with explicit client data, provides its own application window, and returns assertion fields to WebKit. Its [Apple review artifact](https://github.com/manaflow-ai/cmux/releases/tag/browser-apple-review-20260722.1) explicitly states that native iCloud passkey access is unavailable until the managed capability and corresponding profile are approved. The coordinator is useful implementation evidence, not proof of entitlement-free iCloud access.
- [Chromeless](https://github.com/antiwork/chromeless) detects the entitlement at runtime. Without it, the app hides unavailable Web Authentication APIs so sites can offer another sign-in method. Its [build script](https://github.com/antiwork/chromeless/blob/main/build.sh) supports a signed, provisioned build after capability approval and documents launch failure for a restricted entitlement claimed by an unprovisioned ad-hoc build.
- [electron-webauthn-mac](https://github.com/vault12/electron-webauthn-mac) implements a native Apple controller for apps associated with their own website. Its domain association must be authorized by the website's server. It does not grant a general browser access to existing passkeys for unrelated sites.
- [Open Passwords](https://github.com/ManiForoughi2/open-passwords) and [keychain-tools](https://github.com/bryanmatteson/keychain-tools/tree/main/apwh) implement Apple's password-helper protocol for logins and verification codes. Their inspected protocols do not implement native passkey assertions. They do not supply the missing general-browser passkey signing capability.

No inspected implementation provides a verified native Ora route to existing Apple passkeys without suitable signing authorization. Moving an authentication sheet into Ora requires the request to run in an authorized process; copying a native coordinator or adding a Touch ID prompt alone does not establish that authorization. The current locally signed development app lacks the browser passkey entitlement. Native integration remains incomplete.

- [Open Passwords](https://github.com/ManiForoughi2/open-passwords) keeps its worker and encrypted session alive in memory and offers optional Accessibility-based code entry. It still uses Apple's pairing handshake and per-credential authorization. Ora's separate service also survives browser process exits; it does not import this project's password cache.
- [Kylmora's Keychain store](https://github.com/kylmora/kylmora/blob/main/Sources/Kylmora/Passwords/KeychainPasswordStore.swift) saves its own internet-password items and can encounter access prompts for other apps' items. This does not demonstrate seamless access to the modern Apple Passwords vault.
- [Search's password panel](https://github.com/driceroland/Search/blob/main/Sources/Search/Passwords.swift) describes importing credentials into its own Keychain items.
- [DuckDuckGo's extension connection delegate](https://github.com/duckduckgo/apple-browsers/blob/main/SharedPackages/WebExtensions/Sources/WebExtensions/Manager/WebExtensionManager%2BNativeMessaging.swift) does not implement persistent native messaging ports in the inspected revision.
- [Orion's release notes](https://orionbrowser.com/updates/orion-release-notes) document support and fixes for Apple's extension. Its implementation was not available as reusable open-source code in this investigation.

## Possible system-wide frontend

A separate menu bar app and global shortcut could reuse the local transport and fill a selected field through macOS Accessibility. This needs the user's Accessibility permission and per-app testing. An arbitrary native app may not provide a website origin or writable field, so account selection and a checked destination are necessary. Passwords are text that can be filled; passkeys require the website or app's authentication protocol and cannot be inserted as text.

The existing transport is not a system-wide autofill implementation. The authenticated channel is now retained by the private service, but a universal frontend still needs an origin-aware credential-selection client and destination checks. Apple already has a [Passwords menu bar feature](https://support.apple.com/guide/passwords/menu-bar-mchldd5eb88d/mac), but that alone does not establish universal field filling.
