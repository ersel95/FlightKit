# FlightKit — AI Context

> Native macOS SwiftUI app that publishes iOS apps to TestFlight / App Store by
> driving `xcodebuild` + the App Store Connect API. Public, MIT, generic — **no
> customer/app-specific data belongs in this repo.**

## Hard rules

1. **Public repo.** Never commit secrets: API keys, `.p8` contents, real bundle
   IDs / Team IDs, customer names, or local absolute paths. The app's catalog and
   keys live on the user's machine (Application Support + Keychain), never here.
2. The Xcode project is **generated**, not committed. After adding/removing a
   Swift file, update `SOURCES` in `generate_pbxproj.py` and re-run it. The
   `.xcodeproj` is git-ignored.
3. Keep it dependency-free (no SPM/CocoaPods) and macOS 14+ / Swift 5+.
4. File headers: `// Created by Mr. t.`

## Layout

```
FlightKit/
├── FlightKitApp.swift          @main; owns ProjectStore
├── Models/                     AppProject, AppEnvironment, DistributionTarget,
│                               ASCCredentials, ASCBuild, BuildVersionInfo,
│                               PublishStep, PipelineState/PipelineBatch,
│                               PublishError, HealRule
├── Services/                   ProjectStore (App Support catalog), ProjectInspector,
│                               KeychainStore, JWTGenerator, ASCAPIClient,
│                               XcconfigEditor, XcodebuildRunner, ExportOptionsBuilder,
│                               AltoolUploader, SelfHealer, PublishOrchestrator
├── Views/                      ContentView, ProjectListView, ProjectEditorView,
│                               ProjectDetailView, CredentialsEditor, PipelineView
├── Resources/Assets.xcassets
└── FlightKit.entitlements
generate_pbxproj.py             project generator (source of truth for the target)
scripts/                        build-app.sh, build-dmg.sh
.github/workflows/release.yml   tag v* -> DMG + Release + cask bump
Casks/flightkit.rb              Homebrew cask (auto-bumped by CI)
```

## Architecture

- **Catalog**: `ProjectStore` (`@Observable`) persists `[AppProject]` to
  `~/Library/Application Support/FlightKit/projects.json`. Every app is user-added
  via `ProjectEditorView` (picks `.xcworkspace`/`.xcodeproj`, scheme, team, envs).
- **AppProject**: absolute `containerPath`; `workspaceRoot` = its parent (xcconfig
  search root); `xcodebuildContainerArguments` chooses `-workspace` vs `-project`
  by extension. `environments` (configuration + bundle id) drive Test/UAT/Prod;
  `applying(env)` pins the effective configuration/bundle id.
- **Credentials**: `ASCCredentials` (Key ID, Issuer ID, `.p8` PEM) in the Keychain,
  keyed on `project.id`. The ASC API key is account-scoped (serves all app records).
- **Pipeline**: `PublishOrchestrator` runs `PipelineState.steps` for the chosen
  `DistributionTarget`: validate → write xcconfig → exportOptions → archive →
  export (API-key/`-allowProvisioningUpdates` signing) → altool upload → wait for
  processing → (App Store only) attach build to an editable App Store version.
  `SelfHealer` retries known failures. A `PipelineBatch` runs envs sequentially
  for the "All" sweep, stopping on first failure.
- **App Store destination** = TestFlight upload **plus** attaching the processed
  build to an App Store version (created if missing). **Never auto-submits** for
  review.
- **Report**: `PipelineReportView` shows submitted vs ASC-recorded version,
  flagging a store renumber.

## Gotchas

- `.xcworkspace`/`.xcodeproj` are file *packages*. The open panel must allow
  directories + `treatsFilePackagesAsDirectories = false` and **not** restrict by
  `allowedContentTypes` (the package UTI won't match a filename-extension type,
  greying them out). See `ProjectEditorView.pickContainer`.
- JWT signing parses the `.p8` via `P256.Signing.PrivateKey(pemRepresentation:)`
  directly (PKCS#8). Don't reintroduce a DER round-trip — it throws CryptoKit ASN.1
  errors.
- Export must pass the API key (`-authenticationKey*` + `-allowProvisioningUpdates`)
  so signing works without a local Apple ID. Cloud cert creation needs Admin role.
- The log view is an `NSTextView` (`SelectableLogView`) for full selection and
  performant streaming; tail-follow uses `didLiveScroll` (user scroll only).

## Build / release

```sh
python3 generate_pbxproj.py && open FlightKit.xcodeproj
scripts/build-dmg.sh 1.0.0
git tag v1.0.0 && git push origin v1.0.0   # CI builds DMG + release + cask
```
