<div align="center">
  <img width="150" height="150" src="/assets/icon.png" alt="Ora Browser logo">
  <h1>Browser development fork</h1>
  <p>A native WebKit browser for macOS, based on Ora.</p>
  <a href="https://vercel.com/oss">
  <img alt="Vercel OSS Program" src="https://vercel.com/oss/program-badge.svg" />
</a>
</div>
<br/>
<p align="center">
  <a href="https://www.apple.com/macos/"><img src="https://badgen.net/badge/macOS/15+/blue" alt="macOS 15+"></a>
  <a href="https://developer.apple.com/xcode/"><img src="https://badgen.net/badge/Xcode/15+/blue" alt="Xcode 15+"></a>
  <a href="https://swift.org"><img src="https://badgen.net/badge/Swift/5.9/orange" alt="Swift 5.9"></a>
  <a href="https://brew.sh"><img src="https://badgen.net/badge/Homebrew/used/yellow" alt="Homebrew"></a>
  <a href="LICENSE"><img src="https://badgen.net/badge/License/GPL-3.0/green" alt="GPL-3.0"></a>
</p>

> [!NOTE]
> This fork is in active development. The app currently uses Ora Dev as its working display name.

## Fork build identity

This repository maintains a fork of [the upstream Ora browser](https://github.com/the-ora/browser).
The permanent browser identifier is independent of its eventual product name.

| Build | App identifier | Configuration |
|---|---|---|
| Browser review | `io.github.kevinjohncutler.browser` | `project.browser.yml` |
| Existing development install | `io.github.kevinjohncutler.Ora.dev` | `project.dev.yml` |

The browser review's embedded password service uses
`io.github.kevinjohncutler.browser.PasswordBridge`. Its native-passkey configuration is
`project.browser-passkeys.yml`.

Native Apple passkey access requires Apple's managed browser capability and a matching
approved provisioning profile. The current review build does not claim that restricted
entitlement or working Apple passkey credential release. The capability request is pending.
An Individual developer membership does not meet Apple's published organization requirement;
the request asks Apple to consider that limitation. No approval is claimed.

The review build is prepared separately from the existing development install. It does not
replace the installed app or migrate browser data. This repository currently publishes source;
a compiled review build has not been published as a release.

## Overview

Ora is a macOS browser built with SwiftUI, AppKit, and WebKit. The project aims for a native, low-friction browsing experience without layering on unnecessary product surface area.

## Highlights

- Native macOS UI
- WebKit-based browsing
- Built-in content blocking and privacy protections
- Search engine customization
- URL suggestions and quick launcher
- Developer-focused features

## Quick Start

```bash
git clone --branch dev/claude-improvements https://github.com/kevinjohncutler/browser.git
cd browser
./scripts/setup.sh
ORA_DEVELOPMENT_TEAM="$SIGNING_TEAM" scripts/build-browser-review.sh
```

The setup script installs required tooling, installs git hooks, and regenerates the Xcode project.
Set `SIGNING_TEAM` to your Apple Developer team identifier before building. The review script
creates a signed app in a separate local build directory without launching or installing it.
Use `scripts/test-headless.sh` for headless validation. See the
[password integration and signing documentation](integration/ora-passwords/README.md) for
native passkey provisioning and the existing development installation workflow.

## Development

- Main app target: `ora`
- Project configuration is managed with `XcodeGen` in `project.yml`
- Regenerate the project after config changes with `xcodegen`
- Run tests in Xcode with `Product > Test` or via `xcodebuild test -scheme ora -destination "platform=macOS"`

Signed development builds use `scripts/build-dev.sh` with `ORA_DEVELOPMENT_TEAM` set to your signing team. The build records its date, revision, and build number in Settings > General. Install it with `python scripts/install-dev.py "$ORA_APP_PATH"`, where `ORA_APP_PATH` points to the built app bundle. The installer verifies the signature, retains a previous bundle for recovery, and updates Finder's bundle dates at the stable `~/Applications/OraDev.app` location without launching or quitting the browser.

The optional Google admission probe reads an account identifier from a private file named by `TEST_RUNNER_ORA_GOOGLE_ACCOUNT_FILE`, with output directed by `TEST_RUNNER_ORA_GOOGLE_ADMISSION_OUTPUT`. Run `scripts/test-headless.sh -only-testing:oraTests/GoogleAdmissionTests`. It stops before password entry, records outcome labels and navigation paths without query strings, and redacts the account identifier in snapshots. A pending passkey challenge counts as admission, not completed authentication or a rendered password screen. Delete the input file after the probe. The ordinary test run skips this network/account-backed check.

## Docs

- [Contributing](CONTRIBUTING.md)
- [Roadmap](ROADMAP.md)
- [Wiki](https://github.com/the-ora/browser/wiki)
- [Security](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Upstream links

- [Website](https://www.orabrowser.com)
- [Discord](https://discord.gg/9aZWH52Zjm)
- [GitHub Sponsors](https://github.com/sponsors/the-ora)
- [Buy Me a Coffee](https://buymeacoffee.com/orabrowser)
- [X / Twitter](https://x.com/orabrowser)

## License

Ora Browser is licensed under [GPL-3.0](LICENSE). Third-party libraries used by this project are licensed under their own open-source licenses.
