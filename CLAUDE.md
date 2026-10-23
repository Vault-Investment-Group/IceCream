# CLAUDE.md — IceCream (the TV Club fork)

A fork of upstream IceCream (CloudKit sync for Realm, in Swift), kept for one app, TV Club. The app pins it by git
tag, and **the app's `Podfile` is the source of truth for which tag** (on 2026-10-23 it pins `2.0.4-tvclub.8`). This
repo is public: keep secrets, keys, tokens and names out of it, its commits and its PRs.

Every fact below was read from a query of the repo on 2026-10-23 (`git tag`, `git log`, `git branch -r`,
`git rev-list --count`, `git show <ref>:IceCream.podspec`). Where the code and this file disagree, the code wins and
this file gets fixed.

## Branches and tags (checked 2026-10-23)

**`master` is the default branch, not the release line.** The release line is `tvclub/release`, whose head is the
newest tag, `2.0.4-tvclub.8`. Fork PRs #2 and #3 targeted `tvclub/release`; PR #1 targeted `master`.

| Ref | `RealmSwift` in `IceCream.podspec` |
|---|---|
| `master` | `< 10.8.0` |
| `2.0.4-tvclub.8` (= `tvclub/release`) | `>= 10.45, < 11` |

- `git rev-list --count 2.0.4-tvclub.8..master` is **1**: `6a42a58`, PR #1's merge (the BackgroundWorker fix).
- `git rev-list --count master..2.0.4-tvclub.8` is **11**: everything from `2.0.4-tvclub.1` on, plus the four 2020–2022
  commits `2.0.4-tvclub.1` builds on (`6aeaff2` to `d116929`, the `add-init-completion` branch).
- `master`'s source matches neither: it has the BackgroundWorker fix but none of the other fork changes, and an
  app-incompatible Realm range.

**The fork's tags:** `2.0.4-tvclub.1`, `.2`, `.4`, `.5`, `.6`, `.7` and `.8`. Each is cut on the one before
(`.1` on `d116929`). There's no `.3`: it was cut from `master`, the app's `pod install` refused its Realm range, and it
was deleted rather than re-pointed.

**Upstream's tags stay:** `0.1.0` to `1.13.2` (upstream's `2.x` tags aren't in this fork). The podspec's
`s.version` is still upstream's `2.0.4` and its `s.source` still points at upstream; the app pins this repo by URL and
tag, so neither is read.

**Other branches** (`git branch -r`):

| Branch | Head | What it is |
|---|---|---|
| `tvclub/relax-realm-pin` | `3a9f905` (= `.2`) | The `.1` and `.2` work |
| `tvclub/background-worker-fix` | `c7f936f` (= `.4`) | The `.4` work |
| `tvclub/a4-teardown-cancellation` | `d1b8837` (= `.6`) | The `.5` and `.6` work |
| `feature/sync-event-hooks` | `a558ed8` | PR #2's branch, squash-merged as `.7` |
| `feature/swappable-database` | `999e797` | PR #3's branch, squash-merged as `.8` |
| `add-init-completion` | `d116929` | The 2020–2022 commits (an init completion handler, Realm 10.x) that `.1` builds on |
| `feature/list-support`, `feature/os-log`, `fix/issue-143` | 2019–2020 | Upstream's, untouched |

## How a fork change ships

1. **A PR here, based on `tvclub/release`.** First check that its head is still the newest tag
   (`git rev-parse tvclub/release` equals `git rev-parse <newest tag>^{commit}`). Never base on `master`.
2. **Then a new tag:** the next number after the newest (`2.0.4-tvclub.9` after `.8`), on the merged
   `tvclub/release`, so it is cut on the newest release tag. Never cut a tag from `master`.
3. **Before tagging,** check the podspec at the commit being tagged:
   `git show <commit>:IceCream.podspec | grep RealmSwift` must show `'>= 10.45', '< 11'`.
4. **Never move or reuse a tag.** The app's builds resolve by tag, and `Podfile.lock` records what a tag resolved to.
   A wrong tag is the app owner's call (`.3` was deleted, not re-pointed).
5. **The app's `Podfile` bump is its own PR in the app's repo,** on macOS, where `pod install` must resolve the new
   tag. That step is what caught `.3`.

A change here that the app should use isn't done until that `Podfile` PR lands.

## Each tag's change

From `git log` between consecutive tags; each is one commit. `docs/CHANGELOG.md` is upstream's and stops at `1.12.0`,
so it records none of these.

| Tag | Commit | Change |
|---|---|---|
| `2.0.4-tvclub.1` | `321650a` | The podspec's `RealmSwift` relaxed to `>= 10.45, < 11` (for Realm's privacy manifest); source unchanged from `d116929`. |
| `2.0.4-tvclub.2` | `3a9f905` | `CKRecordConvertible`: `List<Object>` serialization reads `RLMSwiftCollectionBase` / `_rlmCollection`, since modern Realm dropped `ListBase` / `_rlmArray`. |
| `2.0.4-tvclub.4` | `c7f936f` | `BackgroundWorker`: no shared mutable state. The block now travels with each message instead of in a shared property (concurrent `start()` calls over-released it), and the thread is created once in `init()`, with a port so its runloop blocks instead of spinning. Adds `isThreadFinished`. |
| `2.0.4-tvclub.5` | `eb3b3de` | `OperationRegistry` plus `SyncEngine.stop()`: every operation a database manager adds registers weakly, and `stop()` cancels what's still in flight, so two engines in a row don't start the same long-lived operation twice. |
| `2.0.4-tvclub.6` | `d1b8837` | `OperationRegistry`'s stop latch: after `cancelAll`, a late registration is cancelled at registration. |
| `2.0.4-tvclub.7` | `a8a3032` | Two optional hooks, `SyncEngine.eventReporter` and `SyncEngine.writeHold` (`SyncHooks.swift`), nil by default (PR #2). |
| `2.0.4-tvclub.8` | `4bea98f` | An optional `SyncEngine.databaseStandIn`, for tests, nil by default (PR #3). |

## What not to run

- **`.github/workflows/deploy_to_cocoapods.yml`** is upstream's manual (`workflow_dispatch`) publish to CocoaPods trunk
  (`pod trunk push`). The fork isn't published there, so it's never run. `scripts/push.sh` does the same push; never
  run it either.
- **`.travis.yml`** is upstream's too (`swift build` on `xcode11.3`), and nothing runs it here.

## Build and test

The library needs macOS and Xcode. There's no test target in this repo; the app's own suite is what tests the fork.

| What the repo provides | The command it implies | Status |
|---|---|---|
| `IceCream.podspec` | `pod lib lint --allow-warnings` | Not run: needs macOS |
| `IceCream.xcodeproj` (schemes `IceCream`, `IceCream-macOS`, `IceCream-tvOS`, `IceCream-watchOS`) | `xcodebuild -project IceCream.xcodeproj -scheme IceCream build` | Not run: needs macOS |
| `Example/` (`IceCream_Example.xcodeproj`) | Build and run the example app in Xcode | Not run: needs macOS |
| `Package.swift` | `swift build` | Not run: needs macOS. It still declares upstream's `realm-cocoa` `from: "4.1.1"`, not the podspec's range; the app uses CocoaPods, not this manifest. |
| `Cartfile` | `carthage update` | Not run: needs macOS |

## `tv-club-icecream`

An older, private, untagged copy of IceCream in the same GitHub organization, last pushed 2025-02-15 (GitHub's
`pushed_at`, 2026-10-23). The app doesn't use it, and changes don't go there; they go here, under a new tag.
