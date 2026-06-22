# FlightKit

A small, native **macOS app** that publishes your iOS apps to **TestFlight** or the
**App Store** — pick an app, choose a version, hit upload. FlightKit drives
`xcodebuild` and the App Store Connect API for you (archive → export → upload →
wait for processing → optional App Store version attach), with a self‑healing
pipeline and a clear, copyable log.

> No Xcode Organizer dance, no manual `altool`. One window, one button.

## Features

- **TestFlight or App Store** per run. App Store additionally attaches the
  processed build to an editable App Store version (created if missing) — it is
  **not** submitted for review.
- **Multiple environments** per app (e.g. Test / UAT / Prod, each a configuration +
  bundle id) — publish one, or **All** in sequence.
- **App Store Connect API key signing** — uses your `.p8` to create cloud‑managed
  distribution certificates & profiles; no interactive Apple ID needed.
- **Self‑healing pipeline** — common failures (missing exportOptions, signing
  fallback, stale archive, package resolution) are retried automatically.
- **Publish report** — what you submitted vs what App Store Connect actually
  recorded, flagged if the store renumbered the build.
- **Native log console** — full text selection, ⌘F, follow‑tail toggle.
- **Teams notification** (optional, per app) — when a batch finishes, post the
  released version into a Microsoft Teams chat automatically. Works even when your
  org has locked down webhooks and Power Automate (it drives the local Teams app).
  See [docs/teams-notifications.md](docs/teams-notifications.md).
- Your apps and API keys stay on your machine (catalog in Application Support,
  keys in the Keychain).

## Install

### Homebrew (recommended)

```sh
brew tap ersel95/flightkit https://github.com/ersel95/FlightKit
brew install --cask flightkit
```

### DMG (any Mac)

1. Open [**Releases**](https://github.com/ersel95/FlightKit/releases) and download
   the latest `FlightKit-<version>.dmg`.
2. Double‑click the `.dmg` to mount it.
3. Drag **FlightKit** onto the **Applications** shortcut in the window.
4. Eject the disk image and launch FlightKit from Applications (or Launchpad).

> Release builds are **signed with a Developer ID and notarized by Apple**, so
> they launch on any Mac with **no Gatekeeper warning** — even offline (the
> notarization ticket is stapled). Nothing extra to run.
>
> (Only builds you compile yourself from source are unsigned. If macOS ever blocks
> one, clear the quarantine flag: `xattr -dr com.apple.quarantine /Applications/FlightKit.app`.)

## Usage

1. **Add an app** — pick its `.xcworkspace` or `.xcodeproj`, set the scheme, Team
   ID, and one or more environments (configuration + bundle id).
2. **Configure the API key** — App Store Connect → Users and Access → Integrations →
   App Store Connect API. Create a key (Admin or App Manager) and paste the Key ID,
   Issuer ID and `.p8` contents. Stored in your Keychain.
3. **Choose destination** (TestFlight / App Store) and **environment** (or All).
4. Set the marketing version and build number (**Suggest next** picks a safe one)
   and **Upload**.
5. *(Optional)* In the app editor's **Teams** section, turn on notifications and
   paste a Teams chat link to get an automatic "released" message after each batch.
   First use asks for Accessibility permission — see
   [docs/teams-notifications.md](docs/teams-notifications.md).

### Requirements

- macOS 14+, Xcode 15+ installed (FlightKit shells out to `xcodebuild`).
- A valid App Store Connect API key. Creating cloud‑managed distribution
  certificates needs the **Admin** role; **App Manager** can upload but may not be
  able to create new certificates.

## Build from source

The Xcode project is generated from `generate_pbxproj.py` (so it never drifts and
isn't committed):

```sh
python3 generate_pbxproj.py        # writes FlightKit.xcodeproj
open FlightKit.xcodeproj            # or:
scripts/build-app.sh Release        # -> dist/FlightKit.app
scripts/build-dmg.sh 1.0.0          # -> dist/FlightKit-1.0.0.dmg
```

## Releasing

Push a tag and CI builds the DMG, publishes a GitHub Release, and bumps the
Homebrew cask:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

## License

MIT — see [LICENSE](LICENSE).
