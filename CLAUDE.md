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
3. macOS 14+. **Sparkle** (auto-update) is the **only** allowed dependency, pulled
   via SPM and wired into the generated project by `generate_pbxproj.py`. Do not add
   other SPM/CocoaPods dependencies without a comparably strong reason.
4. **Must compile clean under Swift 6 language mode.** The CI toolchain is stricter
   than a local Xcode may be — verify locally before pushing a release tag:
   `xcodebuild -project FlightKit.xcodeproj -scheme FlightKit -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO SWIFT_VERSION=6 build`
5. **SwiftUI view structs are `@MainActor`.** Every `View`/`NSViewRepresentable`
   (and its Coordinator) is annotated `@MainActor` so helper methods can touch the
   `@MainActor` models (`PipelineState`, `ProjectStore`). Without it the strict CI
   compiler errors ("can not be referenced from a non-isolated context"). `FlightKitApp`
   is `@MainActor` too, so `@State = ProjectStore()` builds.
6. File headers: `// Created by Mr. t.`

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
│                               AltoolUploader, SelfHealer, PublishOrchestrator,
│                               TeamsNotifier
├── Views/                      ContentView, ProjectListView, ProjectEditorView,
│                               ProjectDetailView, CredentialsEditor, PipelineView
├── Resources/Assets.xcassets
└── FlightKit.entitlements
generate_pbxproj.py             project generator (source of truth for the target)
scripts/                        build-app.sh (unsigned), build-dmg.sh (local unsigned),
                                release-dmg.sh (sign + notarize + staple, used by CI)
.github/workflows/release.yml   tag v* -> sign + notarize + Release + cask bump
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
- **Pipeline**: `PublishOrchestrator` runs `PipelineState.steps` (the *blocking*
  steps) for the chosen `DistributionTarget`: validate → write xcconfig →
  exportOptions → archive → export (API-key/`-allowProvisioningUpdates` signing) →
  altool upload. **The pipeline ends at upload.** ASC processing — and, for App
  Store, the version attach — runs *afterwards* as a non-blocking background watch
  (`runProcessingWatch`), so a multi-env sweep never waits up to 30 min per env on
  another's processing. `SelfHealer` retries known failures.
- **Processing watch**: `PipelineState.processingPhase` (`ProcessingPhase`: idle →
  waiting → valid → (App Store) attaching → attached / failed / stopped) tracks the
  post-upload work. Started per env by the batch runner; **only runs while the
  pipeline screen is open** — `PipelineView.onDisappear` cancels the watches
  (`PipelineBatch.cancelProcessingWatches`), flipping any in-flight watch to
  `.stopped`. The live status shows in the steps panel and the report.
- **Environment selection**: a multi-select chip picker (any subset, e.g. Test +
  Prod) — there is no "All" button. `targetEnvironments` filters
  `resolvedEnvironments` by the ticked names (single-env projects always publish
  their one env). The picked subset **and** destination are remembered per project
  across launches in `UserDefaults` (`FlightKit.envSelection.<id>` /
  `FlightKit.destination.<id>`), restored in `ProjectDetailView.restoreSelection`.
- **Git branch per environment** (optional): `GitBranchInspector` lists the repo's
  branches (local + already-fetched remotes, deduped on the short name) and the
  publish screen shows one picker per target env — e.g. Test ← `tst`, UAT ← `uat`,
  Prod ← `liv`. A pick is remembered per project+env in `UserDefaults`
  (`FlightKit.branch.<id>.<env>`) and pruned when the branch disappears. Picking a
  branch prepends a `checkoutBranch` step (`PublishStep.steps(for:branchSelected:)`)
  that runs **before** validate, so the version write and archive read the right
  sources; the repo is left on that branch (a batch's next env checks out its own).
  Nothing is stashed or forced: a dirty tree is only *warned* about, and a checkout
  git refuses fails the step with git's own message. Not picking = old behaviour
  (build the working copy as-is, no checkout step listed).
- **App Store destination** = TestFlight upload **plus** auto-attaching the
  processed build to an App Store version (created if missing) once processing
  reaches VALID — done in the background watch, so it only completes if the screen
  stays open until processing finishes. **Never auto-submits** for review.
- **Batch**: a `PipelineBatch` runs the picked envs' blocking pipelines
  sequentially, stopping on first failure; each successful upload then spawns an
  independent processing watch.
- **Report**: `PipelineReportView` shows submitted vs ASC-recorded version,
  flagging a store renumber.
- **Teams notification** (optional, per `AppProject`): when set, the batch posts a
  single summary of the successfully-uploaded envs to a Teams chat once all blocking
  uploads finish (`ProjectDetailView.notifyTeamsIfNeeded` — one message per batch, not
  per env). For orgs that have locked down Incoming Webhooks **and** the Power Automate
  portal there is no server-side path, so `TeamsNotifier` drives the **local Teams
  desktop app**: clipboard → open `https://teams.microsoft.com/l/chat/…` deep link
  (focuses the compose box) → synthesize `⌘V` + `Return` via `CGEvent` → restore the
  clipboard. `teamsChatLink`/`teamsNotifyEnabled` are optional on `AppProject` (old
  `projects.json` decodes unchanged); the link lives only in the local catalog, never
  committed. See `docs/teams-notifications.md`.
- **Auto-update (Sparkle)**: `UpdaterController` owns `SPUStandardUpdaterController`
  (`UpdaterView.swift`); a "Güncellemeleri Denetle…" menu item sits under the app
  menu. `Info.plist` carries `SUFeedURL` (the appcast on raw `main`), `SUPublicEDKey`,
  `SUEnableAutomaticChecks=YES`, `SUAutomaticallyUpdate=NO` → checks on launch +
  daily, **notifies and asks** before installing (never silent). The feed
  `appcast.xml` lives at the repo root; CI signs each DMG with EdDSA (`sign_update`)
  and `scripts/update_appcast.py` inserts the new `<item>`. The app's bundle version
  is stamped from the git tag at release time (`build-app.sh <cfg> <version>`), so
  Sparkle can compare it against the feed.

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
- `writeXcconfig` is **best-effort**: many projects keep the version in build
  settings, not `.xcconfig`. Never make it fatal — the archive injects
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` as command-line overrides anyway.
- The log view is an `NSTextView` (`SelectableLogView`) for full selection and
  performant streaming; tail-follow uses `didLiveScroll` (user scroll only).
- **Sparkle signing**: the release build is unsigned (`CODE_SIGNING_ALLOWED=NO`), so
  `release-dmg.sh` must sign every nested Sparkle component (XPCServices, `Autoupdate`,
  `Updater.app`, then the framework) with hardened runtime + timestamp **before** the
  outer app — signing the app seals its contents. Use `--preserve-metadata=entitlements`
  on the XPC services. Don't reach for `--deep`.
- **Sparkle bootstrap**: a build without Sparkle can't auto-update — users on such a
  build must update once manually to a Sparkle-enabled release; auto-update works from
  there. The `appcast.xml` URL 404s until the first Sparkle release populates it.
- **Teams notify needs Accessibility, not a webhook.** `TeamsNotifier` posts
  synthetic keystrokes (`CGEvent`), which require the app to be **trusted for
  Accessibility** (System Settings → Privacy & Security → Accessibility). This works
  because the app is **unsandboxed** (`app-sandbox = false` in `FlightKit.entitlements`)
  — don't enable the sandbox or this breaks. The permission resets per rebuild for a
  dev build but is stable for the notarized release. Use the literal key string
  `"AXTrustedCheckOptionPrompt"` (the `kAX…` global var isn't concurrency-safe under
  Swift 6). The `&message=` deep-link param does **not** prefill for `…@thread.v2`
  chat links — that's why we paste instead of putting the text in the URL.
- `ProjectStore.init` is a normal (`@MainActor`) init; do **not** make it
  `nonisolated` — a nonisolated init can't assign the `@MainActor` `projects`.
  `FlightKitApp` being `@MainActor` is what lets `@State = ProjectStore()` build.

## Build / release

```sh
python3 generate_pbxproj.py && open FlightKit.xcodeproj     # dev
scripts/build-dmg.sh 1.0.0                                  # local UNSIGNED dmg
git tag v1.0.0 && git push origin v1.0.0                    # CI: sign+notarize+release
```

Release builds are **Developer ID signed + notarized + stapled** (app and DMG).
CI (`release.yml`) needs these repo **secrets**:
`DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `SIGNING_IDENTITY`,
`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`, and **`SPARKLE_ED_PRIVATE_KEY`**
(the 44-char base64 EdDSA private key — `generate_keys --account flightkit -x -`;
the public half is `SUPublicEDKey` in `Info.plist`). The notarization ASC key must
belong to the **same team** as the signing cert. `scripts/release-dmg.sh` runs the
build → **sign Sparkle.framework inside-out** → sign app → notarytool → staple → DMG
flow; the workflow then EdDSA-signs the DMG and updates `appcast.xml` on `main`.

Distribution: GitHub Releases (`FlightKit-<v>.dmg`) and `brew install --cask flightkit`
(tap `ersel95/flightkit`). v1.0.0 shipped & verified notarized (2026-05-22).
