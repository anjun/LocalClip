# Configurable Retention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded retention summary with persisted count/age selectors, including permanent age retention and confirmed immediate cleanup when limits are reduced.

**Architecture:** Keep `AppSettings` as the source of retention values and add pure validation/reduction helpers there. `AppModel` owns the mutation boundary, persists through its existing JSON payload, synchronizes `ClipboardStore`, and runs destructive pruning off the main actor. A failed reduction rolls the complete prior retention pair back in the model, Store, and persisted payload. `SettingsView` owns only draft/pending UI state and delegates accepted changes to the model.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit on macOS 13+, Foundation `UserDefaults`, SQLite-backed `ClipboardStore`, custom `LocalClipTestRunner`.

## Global Constraints

- Default retention remains exactly `200` items and `7` days.
- Count choices are exactly `50`, `100`, `200`, `500`, and `1000`.
- Age choices are exactly `1`, `3`, `7`, `14`, `30`, and `0` (`0` means permanent).
- Permanent disables only age pruning; count pruning remains active.
- Lowering either effective limit requires confirmation and prunes immediately after confirmation.
- Raising a limit or selecting permanent saves without confirmation.
- Pruning never runs on the main actor.
- A prune failure must retain its error status but roll back the complete prior retention pair everywhere; it must never retain the failed proposed limits.
- Existing positive non-preset persisted values remain visible and usable until the user selects a preset.
- One dual text/image capture continues to count as two stored items.

---

### Task 1: Retention Policy Semantics

**Files:**
- Modify: `Sources/LocalClipCore/AppSettings.swift`
- Modify: `Sources/LocalClipCore/ClipboardStore.swift`
- Test: `Sources/LocalClipTestRunner/main.swift`

**Interfaces:**
- Produces: `AppSettings.retentionMaxItemOptions: [Int]`
- Produces: `AppSettings.retentionMaxAgeDayOptions: [Int]`
- Produces: `AppSettings.isValidRetention(maxItems:maxAgeDays:) -> Bool`
- Produces: `AppSettings.isRetentionReduction(fromMaxItems:fromMaxAgeDays:toMaxItems:toMaxAgeDays:) -> Bool`
- Consumes: `ClipboardStore.settings.maxAgeDays`, where `0` skips age pruning.

- [ ] **Step 1: Add failing pure-policy and permanent-retention tests**

Add `runRetentionPolicyTests()` to the runner entry point and implement assertions equivalent to:

```swift
static func runRetentionPolicyTests() {
    print("--- retention policy ---")
    expect(AppSettings.retentionMaxItemOptions == [50, 100, 200, 500, 1000], "retention item presets")
    expect(AppSettings.retentionMaxAgeDayOptions == [1, 3, 7, 14, 30, 0], "retention age presets")
    expect(AppSettings.isValidRetention(maxItems: 200, maxAgeDays: 0), "permanent retention valid")
    expect(!AppSettings.isValidRetention(maxItems: 0, maxAgeDays: 7), "zero item limit invalid")
    expect(!AppSettings.isValidRetention(maxItems: 200, maxAgeDays: -1), "negative age invalid")
    expect(AppSettings.isRetentionReduction(
        fromMaxItems: 200, fromMaxAgeDays: 7,
        toMaxItems: 100, toMaxAgeDays: 7
    ), "lower item limit is reduction")
    expect(AppSettings.isRetentionReduction(
        fromMaxItems: 200, fromMaxAgeDays: 0,
        toMaxItems: 200, toMaxAgeDays: 30
    ), "permanent to finite age is reduction")
    expect(!AppSettings.isRetentionReduction(
        fromMaxItems: 200, fromMaxAgeDays: 7,
        toMaxItems: 500, toMaxAgeDays: 0
    ), "raising count and selecting permanent is not reduction")
}
```

Add a store test that inserts an item, advances the fixed clock by 31 days, changes to `AppSettings(maxItems: 200, maxAgeDays: 0)`, prunes, and expects the old item to remain.

- [ ] **Step 2: Run the tests and verify RED**

Run: `make test`

Expected: compilation fails because the four `AppSettings` policy members do not exist, proving the test reaches the missing feature.

- [ ] **Step 3: Implement the minimal policy helpers and permanent semantics**

In `AppSettings`, add the exact preset arrays and validation bounded to `1...1_000_000` items and `0...36_500` days. Implement reduction semantics so finite-to-shorter, permanent-to-finite, and lower-count changes return true.

In `ClipboardStore.pruneLocked()`, wrap age pruning with:

```swift
if settings.maxAgeDays > 0 {
    let maxAge = TimeInterval(settings.maxAgeDays) * 24 * 60 * 60
    let cutoff = now.addingTimeInterval(-maxAge)
    let aged = try fetchIdsOlderThanLocked(cutoff)
    for id in aged {
        try deleteLocked(id: id)
    }
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Run: `make test`

Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit the core policy**

```bash
git add Sources/LocalClipCore/AppSettings.swift Sources/LocalClipCore/ClipboardStore.swift Sources/LocalClipTestRunner/main.swift
git commit -m "feat: support configurable retention policy"
```

### Task 2: AppModel Update, Persistence, and Immediate Pruning

**Files:**
- Modify: `Sources/LocalClipCore/AppModel.swift`
- Test: `Sources/LocalClipTestRunner/main.swift`

**Interfaces:**
- Consumes: Task 1 validation and reduction helpers.
- Produces: `AppModel.init(storeRoot:userDefaults:)`
- Produces: `AppModel.updateRetention(maxItems:maxAgeDays:) async -> Bool`
- Produces: `AppModel.isUpdatingRetention: Bool`

- [ ] **Step 1: Add failing AppModel retention tests**

Create `runAppModelRetentionTests()` using a unique `UserDefaults(suiteName:)`, clearing the suite before and after. On the main actor:

1. Create a model with the suite.
2. Seed three distinct records and refresh.
3. Await `updateRetention(maxItems: 2, maxAgeDays: 0)`.
4. Assert the call returned true, model/store settings are `2/0`, model items and store rows are both `2`, and `isUpdatingRetention` is false.
5. Recreate the model with the same suite and assert `2/0` loaded.
6. Call with `maxItems: 0`, assert false, and assert settings remain `2/0`.

Use the runner's existing main-queue plus `RunLoop` pattern to wait for the async main-actor task without blocking it.

- [ ] **Step 2: Run the tests and verify RED**

Run: `make test`

Expected: compilation fails because the injectable initializer, async update API, and update state do not exist.

- [ ] **Step 3: Implement injectable persistence and async update**

Change the initializer to:

```swift
public init(
    storeRoot: URL? = nil,
    userDefaults: UserDefaults = .standard
) throws
```

Store the injected defaults in a private property and replace both `UserDefaults.standard` reads/writes. Add:

```swift
@Published public private(set) var isUpdatingRetention = false
```

Implement `updateRetention` to:

1. Reject invalid values without mutating settings or Store.
2. Compute whether the change is a reduction.
3. Update both settings fields and call existing `persistSettings()`.
4. Return immediately with success for non-reductions.
5. For reductions, set `isUpdatingRetention`, execute `store.prune()` in `Task.detached(priority: .utility)`, then call synchronous `refresh()` on the main actor.
6. On prune error, restore the complete prior settings through `persistSettings()` so `AppModel.settings`, `ClipboardStore.settings`, and the injected `UserDefaults` payload all return to the old pair; then set a Chinese status message and return false.
7. Always restore `isUpdatingRetention` to false.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `make test`

Expected: `ALL TESTS PASSED`, including restored settings in the second model.

- [ ] **Step 5: Commit the model boundary**

```bash
git add Sources/LocalClipCore/AppModel.swift Sources/LocalClipTestRunner/main.swift
git commit -m "feat: persist and apply retention changes"
```

### Task 3: Settings Selectors and Reduction Confirmation

**Files:**
- Modify: `Sources/LocalClipApp/LocalClipApp.swift`

**Interfaces:**
- Consumes: Task 1 preset arrays and reduction helper.
- Consumes: Task 2 `updateRetention(maxItems:maxAgeDays:) async -> Bool` and `isUpdatingRetention`.
- Produces: two Settings pickers with local accepted state and a pending confirmed proposal.

- [ ] **Step 1: Establish the failing UI build**

Replace only the hard-coded retention text with references to the new UI state and `AppSettings.retentionMaxItemOptions`; do not add the state or helpers yet.

Run: `swift build -c debug`

Expected: compilation fails on missing retention UI state/helper symbols, proving the application target is being built.

- [ ] **Step 2: Implement picker state and proposal flow**

Add local state initialized on appearance:

```swift
@State private var retentionMaxItems = AppSettings.default.maxItems
@State private var retentionMaxAgeDays = AppSettings.default.maxAgeDays
@State private var pendingRetention: (maxItems: Int, maxAgeDays: Int)?
@State private var showsRetentionConfirmation = false
```

Render “最多保留” and “保留时长” rows with menu-style `Picker`s. Build each choice list from its presets plus the current value so a legacy non-preset value remains visible. Label age `0` as “永久”.

The picker binding setter proposes a complete `(maxItems, maxAgeDays)` pair. If `AppSettings.isRetentionReduction(...)` is true, store it as pending and show an alert without changing accepted local state. Otherwise apply immediately. The alert has “取消” and destructive “清理并应用”; only the destructive action applies the pending pair.

`applyRetention` updates accepted local state, launches a main-actor `Task`, awaits the model API, and restores both local values from `model.settings` if the update fails. For a failed reduction, the model has already rolled back to the previous accepted pair. Disable both pickers while `model.isUpdatingRetention`.

- [ ] **Step 3: Build and inspect the resulting source**

Run: `swift build -c debug`

Expected: `Build complete!`.

Run:

```bash
rg -n '最多 200 条 · 保留 7 天|Picker|清理并应用|isUpdatingRetention' Sources/LocalClipApp/LocalClipApp.swift
```

Expected: no hard-coded summary match; two Picker usages, one confirmation action, and disabled-state wiring are present.

- [ ] **Step 4: Commit the Settings UI**

```bash
git add Sources/LocalClipApp/LocalClipApp.swift
git commit -m "feat: configure retention in settings"
```

### Task 4: Documentation and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`

**Interfaces:**
- Documents the shipped behavior from Tasks 1–3.

- [ ] **Step 1: Update both README files**

Change the usage copy to state that Preferences offers count and duration controls and that the default remains `200 items / 7 days`. Mention that duration can be permanent while count retention still applies.

- [ ] **Step 2: Run the complete automated test runner**

Run: `make test`

Expected: `ALL TESTS PASSED` and exit code `0`.

- [ ] **Step 3: Build the complete application in release mode**

Run: `swift build -c release`

Expected: `Build complete!` and exit code `0`.

- [ ] **Step 4: Audit requirements and working tree**

Run:

```bash
git diff --check
rg -n '最多 200 条 · 保留 7 天' Sources README.md README.en.md
git status --short
```

Expected: no whitespace errors; no hard-coded settings summary in Sources; only intentional feature files are modified.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md README.en.md
git commit -m "docs: explain configurable retention"
```
