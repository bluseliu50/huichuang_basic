# AGENTS.md — huichuang_basic

Guidance for AI coding agents (and humans) working in this repository.

## Project

Unofficial Flutter client for 国家中小学智慧教育平台 (basic.smartedu.cn).
Product name: **惠窗中小学端**. Platforms: macOS / Windows / Linux / Android / iOS.
License: **CC BY-NC-SA 4.0 — non-commercial**. Never add code whose purpose is
commercial distribution.

## Hard rules

1. **NEVER commit secrets.** No tokens, `access_token` / `refresh_token` values,
   passwords, account numbers, API keys, `.env*`, `*.key`, `dev_secrets*.json`,
   `*token*.txt`. These paths are gitignored from the first commit — keep it that
   way. Before every push, audit the full history for leaked credentials —
   substitute the real test-account phone and password from your gitignored
   `dev_secrets.json`, then run:
   `git log -p | grep -iE '<phone>|<password>|access_token"[[:space:]]*[:=]|refresh_token"[[:space:]]*[:=]'`
   and confirm no *values* (test fixtures with dummy data are fine; real
   credentials are not). Test accounts go in a gitignored `dev_secrets.json`
   under the repo root or `/tmp`, never in the repo.
2. **Do not regress the pinned fixes** (see "Load-bearing decisions" below).
3. Platform API facts live in `.agents/skills/smartedu-streaming/SKILL.md`
   (exposed to Claude Code via the committed `.claude/skills/smartedu-streaming`
   relative symlink — do not delete that link). If the platform changes,
   re-verify with curl/browser first, fix code, then update that skill — it is
   the durable knowledge base.
4. Biometric auth gates **only** the credential vault (saved-password unlock),
   never app launch. Tests assert this; keep them green.
5. New dependencies require a strong justification written in the commit body.
   Current dependency set is intentional and locked.

6. **Prefer the harness's own tools over raw shell commands** (this applies
   to every AI agent working here, especially the pi/omp harness's Grep and
   Find/Glob). The harness can batch, anchor and validate built-in calls;
   shell equivalents are shadowed or blocked. Concretely:
   - Text search → `Grep` tool, never bash `grep` / `rg`.
     Example: find token handling → Grep pattern `access_token` in `lib/`.
   - File discovery → `Glob`/Find tool, never `find` / `fd` / `ls **`.
     Example: list tests → Glob `test/**/*_test.dart`.
   - Reading → `Read` with line selectors (`lib/src/api/client.dart:50-120`),
     not `cat` / `head` / `tail`.
   - Editing → `Edit` / `Write` tools, not `sed -i` or output redirection.
   - Symbol-aware navigation → `LSP` (definition / references / rename)
     when a server is available; never regex-rename across files.
   - `Bash` is for real binaries and short fact pipelines (`wc -l`, `md5sum`,
     `fvm flutter …`), one call computing one fact.

7. **Published releases are user-authored.** Never overwrite a release's
   notes/body or re-publish over an edited release. Ship artifacts by
   attaching to the existing release (`attach_tag` workflow input), never by
   recreating it.
8. **Release tags are pinned at the shipped commit.** When a release ships,
   point its tag at the commit whose tree matches the assets and leave it
   there — later pushes never move it. `main` keeps advancing; the next
   release gets its own tag. Pin/move via
   `gh api -X PATCH repos/<owner>/<repo>/git/refs/tags/<tag> -f sha=<full sha>`
   — the refs API needs the full 40-char sha (short shas fail with 422).

## Architecture

```
lib/main.dart                     — bootstrap: proxy startup, providers, E2E hooks,
                                    quit arbiter (deterministic window-close teardown)
lib/src/api/                      — SmarteduClient (dual-mirror failover) + models
   └ catalog.dart                 — CatalogService (tag trees, materials, textbooks,
                                     module_version disk cache, local search)
lib/src/stream/proxy.dart         — 127.0.0.1 auth-injecting HLS/PDF proxy (linchpin)
   └ key_vault.dart               — HLS key dance: md5 sign + AES-128-ECB unwrap
lib/src/auth/                     — AuthController (silent refresh), webview login
   └ token_store.dart, biometric.dart
   └ login_service.dart           — injected credential script + token capture
                                     (all-host watcher, three-path push)
lib/src/store/app_state.dart      — AppController: selection, chapters, history
lib/src/ui/                       — app_shell (adaptive rail/bottom bar), courses,
                                     player (media_kit + custom controls), pdf,
                                     search (local index), settings, home, login
   └ breakpoints.dart             — HcLayout: shared M3 window-size-class rules
                                     (every responsive decision goes through it)
tool/live_check.dart              — real-platform end-to-end proxy verification
tool/webchannel_probe.dart        — login webview capture + close pipeline
                                    probe (neutral page, no real site)
test/                             — unit tests with byte-level real fixtures
third_party/pdfrx                 — vendored pdfrx 2.4.8: createImage
                                    BGRA→RGBA fix + neighbor-page prerender
                                    (wired via dependency_overrides)
third_party/desktop_webview_window — vendored 0.3.0+hc7 (dependency_overrides):
                                    login-window fixes hc1–hc8; full list in
                                    the root pubspec.yaml comment
```

Data flow: UI → AppController → SmarteduClient (public static JSON on
`s-file-{1,2}.ykt.cbern.com.cn`) ; playback → StreamProxy rewrites the playlist
and injects `X-ND-AUTH`, performs the key dance, and fails over
r1→r2→r3 nodes; media_kit (mpv) plays the proxied URL.
Login (desktop): DesktopLoginService injects `credentialInjection` into the
login webview; the injected watcher polls localStorage on EVERY
`*.smartedu.cn` document and pushes the token via legacy `window[name]` →
`window.webkit.messageHandlers` → `window.chrome.webview` (WebView2).

## Build & test

The project pins its Flutter SDK with **fvm** (`.fvmrc`, committed; CI reads
the same file). Always run toolchain commands through fvm:

```bash
fvm install                 # once per machine: SDK for the pinned version
fvm flutter pub get
fvm flutter analyze         # must report: No issues found
fvm flutter test            # must be all green
fvm flutter run -d macos    # daily driver platform
HC_TOKEN=<access_token> fvm dart run tool/live_check.dart   # live proxy proof
```

Verification bar for merging "done" work: `flutter analyze` clean + tests green;
any proxy / player / auth change additionally requires a `live_check` PASS or a
macOS E2E log containing `PLAYER_OPEN` and `PLAYER_DURATION <n>s`.
Login-webview changes additionally require a `tool/webchannel_probe.dart`
PASS: `push received` + `close ok`, exit 0, no coredump.

macOS E2E: `HC_E2E_TOKEN='<full token json>' HC_E2E_RESID=<resId> <debug binary>`.

Do NOT run bare `fvm dart format` on existing files: the pinned SDK formats
with the new tall style while the repo is written in the old short style — a
format pass rewrites whole files as diff noise. Match the surrounding style
by hand. Layout widget tests at arbitrary window sizes live in
`test/narrow_layout_test.dart` — reuse its `_FakeClient`/`_app` harness and
`_narrow(tester, size:)` (791×820 ≈ Pixel 9 Pro Fold inner screen, 892×412 a
landscape phone). Pumping the whole `AppShell` needs an `AuthController` in
the tree and textbooks preloaded, or an IndexedStack tab spins forever and
`pumpAndSettle` times out.

Android on this workstation: `export JAVA_HOME="/Applications/Android
Studio.app/Contents/jbr/Contents/Home"` before gradle/apksigner work. Verify
signatures with `apksigner verify --print-certs` — `keytool -printcert
-jarfile` cannot read APK v2+ schemes. Widget tests that need real IO use
`tester.runAsync`; PDF pixel checks render through `sips -s format bmp`.

## Continuous integration (desktop & android)

`.github/workflows/desktop.yml` builds release bundles for macOS (arm64),
Linux (x64) and Windows (x64) and attaches them to the published release.
It runs on:

1. Manual dispatch: Actions → desktop-build → Run workflow.
2. `release: published` (stable releases; prereleases no-op, see below).
3. Push to `main` — i.e. squash-merged PRs under the PR discipline — EXCEPT
   docs-only pushes: when EVERY commit message in the push is typed
   `docs:` / `docs(...)` the setup gate empties the matrix and the run
   no-ops in seconds (same mechanism as the prerelease gate).

Commit messages never START a build — the docs gate only ever SKIPS one
("编译测试" kick pushes stay banned). All four platforms follow this
policy: `android.yml` gates identically (setup job + `always()`-guarded
build `if`).

Stable releases auto-build; **prereleases do not** — `desktop.yml` opens with
a setup gate whose matrix stays empty for `release: published` events marked
prerelease. Ship a prerelease by dispatching manually with `attach_tag`.

- CI holds no certificates, so the macOS job rewrites signing in the
  checked-out `project.pbxproj` via sed (sdk-scoped identity → `-`,
  Automatic → Manual, team → empty) and builds ad-hoc. Ad-hoc artifacts
  run, but Keychain items do not survive a signing-identity change —
  vault-reliable macOS builds must be signed locally with the real team.
  When `MACOS_CERT_P12_BASE64` / `MACOS_CERT_PASSWORD` secrets exist the job
  imports the P12 into a throwaway keychain and signs with the real identity
  instead (step id `macos_cert`); without them it stays on the sed + ad-hoc
  path.
- Linux window icon: `assets/icon.png` is installed into `data/` by
  `linux/CMakeLists.txt` and loaded relative to `/proc/self/exe` in
  `linux/runner/my_application.cc`. Keep all three in sync with the icon
  master (`assets/icon.png` is the single source for every platform).
- Release assets are installers, not raw build trees: Windows Inno Setup
  `.exe` (`packaging/windows/installer.iss`), Linux deb (built on
  ubuntu-24.04 so the deb's libmpv soname 2 resolves on Arch / Debian 12+ /
  Fedora hosts) + pacman `.pkg.tar.zst` (real `makepkg` as a non-root
  builder inside an `archlinux:base` container; pkgver drops the `-` so
  prereleases vercmp-sort before the final release; nothing published to
  the AUR or any pacman repo; desktop entry in `packaging/linux/`), macOS
  zip containing the `.app` beside an `/Applications` symlink for
  drag-install.
- Auth on hosts WITHOUT secure storage (Linux without a Secret Service):
  the token falls back to an XOR-obfuscated file cache
  (`TokenFileCache`, `~/.config/huichuang_basic/session.bin`) so the login
  state survives restarts — the plaintext password is NEVER written there;
  the biometric vault is inert (switch visible but grayed out).

### Android (android.yml)

Manual dispatch, push to `main` (docs-only pushes skip via the same gate
as desktop.yml), or a **stable** release — `release: published` builds
and attaches the APK automatically; prereleases never start CI here, ship
them by dispatching with `attach_tag`. Inputs: `abi` (`universal` or
`split-per-abi`) and `attach_tag`. The release keystore is decoded from
the `KEYSTORE_BASE64` secret (+ `KEYSTORE_PASSWORD` / `KEY_ALIAS` /
`KEY_PASSWORD`) and gradle
selects the release signing config purely by `HC_KEYSTORE_PATH` being set —
unset locally, builds fall back to the debug keystore. APK names derive from
the pubspec version: `huichuang_basic-v<version>-android.apk` (universal) or
`-<abi>` per split. The pinned Flutter `3.48.0-0.3.pre` resolves only with
`flutter-action`'s `channel: beta`; the stable default fails. Dispatch by
file name (`gh workflow run android.yml`) — the display name can stop
resolving after old runs are deleted.
When the `KEYSTORE_BASE64` secret is absent entirely (mirror repos, manual
test builds) the restore step exits 0 and `HC_KEYSTORE_PATH` is exported
inside the run script only when the keystore file exists — gradle reads the
env var with a non-null check, so an empty-string value would still read as
"set" and break the debug fallback. Debug-signed APKs install only beside
debug builds, never upgrade-in-place over a release install.
- Debug/profile builds carry `.debug` / `.profile` `applicationIdSuffix` so
  they install BESIDE the release app — same applicationId with different
  signing keys fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, and the only
  workaround (uninstall) wipes the release app's data. Release id, CI signing
  and the local debug-signing fallback are untouched; secure storage is keyed
  by package id, so the debug app starts with fresh data (first-run login).
  In Kotlin DSL the profile buildType must be configured via `getByName`
  (the Flutter plugin pre-creates it; bare `profile {}` resolves against the
  Kotlin source-set extension and fails to compile).

## Load-bearing decisions (do not revert without equivalent re-verified fixes)

- `flutter_secure_storage` **v11** + empty `keychain-access-groups` entitlement
  on macOS/iOS — older versions break Keychain (-34018) with custom signing.
- macOS builds with a real Development team/identity (no ad-hoc) for Keychain.
- `StreamProxy` must be wired to `tokenProvider` from AuthController, otherwise
  the proxy fetches without auth and mpv fails with 401.
- Player video area is height-constrained (flex) inside a Column — an
  unconstrained AspectRatio clips the controls layer.
- Every responsive-layout decision goes through `HcLayout`
  (`lib/src/ui/breakpoints.dart`): Material 3 window-size classes — ≥600
  (medium: fold inner portrait ~791dp, tablet portrait, desktop) gets the
  two-pane layouts + navigation rail, ≥840 (expanded) splits the player
  side-by-side, ANY landscape window is two-pane (height is the scarce
  axis). Do not hardcode width thresholds in pages. The portrait player
  stack is a width-driven 16:9 video — it must never render in landscape
  (RenderFlex overflow past the screen height).
- Mobile fullscreen is the `_ImmersiveScope`-wrapped `FullscreenVideoRoute`:
  `immersiveSticky` + landscape lock on enter, `edgeToEdge` + free rotation
  restored on pop (dispose covers the back gesture). Keep the restore —
  other `SystemUiMode`s need an app-wide migration on this SDK.
- Textbook tag tree has a root "电子教材" container; drill into the `zxxxd` layer.
- Remote search (`x-search`) is blocked by WAF TLS/IP fingerprinting — the local
  search index is the final design, do not retry remote search.
- Lesson→chapter mapping uses `lesson.chapter_ids.last`.
- The PDF viewer is the vendored `third_party/pdfrx` (dependency_overrides):
  `createImage` must keep the BGRA→RGBA swap and the neighbor-page prerender
  must stay parallel-safe; regenerating or re-pointing the override loses
  both fixes.
- Login token capture (`lib/src/auth/login_service.dart`): WebKitGTK ≥ 2.46
  exposes script message handlers ONLY as `window.webkit.messageHandlers.<name>`
  (the legacy `window.<name>` object is gone — probed on webkit2gtk-4.1);
  the injected watcher therefore polls localStorage on EVERY `*.smartedu.cn`
  document (the post-login redirect host varies) and pushes through three
  guarded paths — legacy `window[name]`, `window.webkit.messageHandlers`,
  `window.chrome.webview`. Windows receives via
  `addOnWebMessageReceivedCallback` because upstream
  `registerJavaScriptMessageHandler` returns early there — do not fold the
  paths back into one. Windows/Linux enter `https://auth.smartedu.cn/uias/login`
  directly (the portal's JS entry chain never fires inside WebView2);
  macOS keeps the portal entry.
- The vendored `third_party/desktop_webview_window` (0.3.0+hc7) carries
  login-window fixes hc1–hc8 — regenerating or re-pointing the override
  loses them, same contract as pdfrx. hc7/hc8 set
  `WEBKIT_DISABLE_COMPOSITING_MODE` and `WEBKIT_DISABLE_DMABUF_RENDERER`
  via `g_setenv(..., FALSE)` BEFORE `webkit_web_view_new()`: NVIDIA drivers
  SEGV the WebKitWebProcess in EGL teardown on close, the env vars are read
  at web-process spawn, and overwrite must stay FALSE so an explicit user
  override keeps winning. hc5 makes Windows `NavigationStarting` notify-only
  (the upstream cancel→Dart-reply→re-navigate dance loses JS-initiated
  navigations); hc6 keeps `DecidePolicy` from calling the Flutter engine
  inside the WebKit signal (SIGTRAP with bundled WebKitGTK).
- Android release signing hinges on `HC_KEYSTORE_PATH`: set in CI to the
  pinned keystore, absent for local runs (debug signing). The keystore lives
  outside the repo (`~/.android/huichuang-release.keystore` + off-repo
  backup) — losing it means installed devices can never upgrade in place.
- `package_info_plus` must stay `^10.0.0`: older majors pin `win32` ranges
  that conflict with `flutter_secure_storage_windows`' `win32 ^6`.
- Linux window close goes through the quit arbiter (main.dart
  `_QuitArbiter` + `window_manager` preventClose): the open page's
  `activeTeardown` (media_kit player: stop → dispose, unregistering the
  texture while the raster thread is idle) must run BEFORE the engine
  tears down, and `my_application_shutdown` ends the process with
  `_exit(0)` to skip the library atexit chain. Closing straight over a
  live player/texture aborts three ways on NVIDIA driver 610.57.04
  (engine texture-registrar `g_mutex_clear` abort, SEGV, Dart "Callback
  invoked after it has been deleted" from mpv callbacks into a dead
  isolate) and the EGL atexit teardown SEGVs even on a clean close —
  DrKonqi turns every one into a fatal-error dialog (issue #9). Any new
  page owning native-backed resources (player, pdfium renders) registers
  itself in `AppController.activeTeardown`; do not remove the empty-looking
  `_exit` or the preventClose wiring without re-verifying a full
  play-then-close cycle produces zero coredumps.

## Commit convention (English only)

Conventional Commits, imperative mood, ≤72-char summary:

```
<type>(<scope>): <summary>

[optional body: why the change was made, trade-offs, evidence]
```

- **Types**: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `polish`,
  `perf`, `security`
- **Scopes**: `repo`, `core`, `api`, `stream`, `auth`, `ui`, `player`, `pdf`,
  `search`, `settings`, `android`, `ios`, `macos`, `windows`, `linux`
- Body explains **why**, not what the diff shows. Evidence (test counts, log
  lines) goes in the body for streaming/auth changes.
- Commit with the account's noreply address (`git config user.email
  265648257+bluseliu50@users.noreply.github.com`, already set repo-locally):
  the GitHub email-privacy block rejects pushes exposing the private address
  (GH007).
- Commit small and often; one logical change per commit; never rewrite published
  history. Rewrites happen only on the user's explicit order — push with
  `--force-with-lease` and re-point any release tag afterward.
- **Tags**: `vX.Y.Z` (annotated) at milestones — `v0.2.0` playback milestone,
  `v1.0.0` first public release. Tag messages summarize the milestone in
  English. Prerelease tags use the `vX.Y.Z-rc.N` form (`v0.1.0-rc.1` was the
  first).

## Release checklist

1. `flutter analyze` + `flutter test` green; live_check PASS.
2. Secrets audit grep (Hard rule 1) over full history.
3. Bump `version:` in `pubspec.yaml` when tagging a release, and the build
   number (`+N`) with it — Android `versionCode` must strictly increase or
   installed devices reject the update.
4. `git tag -a vX.Y.Z -m "..."` then push `main` and tags together.
5. Pin the release tag to the shipped commit (Hard rule 8) via the refs API
   with the full sha; verify its tree matches the attached assets.
6. Prereleases: publish the release with notes only, then dispatch
   `android-build` / `desktop-build` with `attach_tag=<tag>`; verify attached
   asset names (`huichuang_basic-v<version>-android.apk`, …).
