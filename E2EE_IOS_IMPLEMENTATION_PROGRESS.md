# iOS E2EE Attachment, Forward, and MLS Persistence Progress

This is the implementation ledger for the approved plan. A task is checked only after its code,
tests, and required documentation pass. Partial work remains unchecked and is described in the
append-only progress log.

## Milestones

- [ ] **M0:** Contract and OpenMLS binding locked.
- [x] **M0.5:** iOS E2EE JSON transport emits canonical base64 and safely reads legacy rows.
- [ ] **M1:** MLS persistence/cursor P0 passes crash recovery gates.
- [ ] **M2:** Attachment crypto and durable transfer complete.
- [ ] **M3:** Attachment UI/download/streaming complete.
- [ ] **M4:** Forward complete.
- [ ] **M5:** Multi-device, performance, and rollout gates pass.
- [ ] **M6:** Documentation and API artifacts synchronized.
- [ ] **TODO-M7:** PIN/epoch archive/recovery.

## Active gate: M0

### Contract

- [x] **CON-001:** Extract and match the Web AAD V1 hash vector on iOS.
- [x] **CON-002:** Sort canonical UUIDs by raw 16-byte value.
- [x] **CON-003:** Use one-byte optional markers and big-endian u16 UTF-8 lengths.
- [x] **CON-004:** Reject duplicate attachment UUIDs.
- [ ] **CON-005:** Verify envelope and decrypted manifest contain the same canonical ID set.
- [x] **CON-006:** Require AAD for a text-only forward with an empty attachment list.
- [x] **CON-007:** Gate the legacy non-AAD send lane to plain non-forward/non-attachment text.
- [x] **CON-008:** Use `max(1, ceil(plaintext_size / frame_size))`.
- [x] **CON-009:** Define zero-byte plaintext as a 24-byte ciphertext frame.
- [x] **CON-010:** Correct the Bellboy written size contract.
- [ ] **CON-011:** Add zero-byte vectors to Web, iOS, and Bellboy tests.
- [x] **CON-012:** Document that the 2 GiB cap applies to ciphertext, not plaintext.
- [ ] **CON-013:** Add the maximum-plaintext boundary test.

### OpenMLS binding

- [x] **MLS-001:** Simulator binding smoke test.
- [x] **MLS-002:** Device-architecture binding smoke test.
- [x] **MLS-003:** Swift AAD round-trip test.
- [x] **MLS-004:** Swift exact returned-AAD test.
- [x] **MLS-005:** Tampered AAD/envelope rejection test.
- [x] **MLS-006:** SDK/OpenMLS CI compatibility gate.
- [x] **MLS-007:** Audit OpenMLS process-message error structure.
- [x] **MLS-008:** Add a distinct consumed-ratchet-secret UniFFI error.
- [x] **MLS-009:** Keep malformed/bad-tag messages distinct from consumed messages.
- [x] **MLS-010:** Regenerate and install Swift bindings/XCFramework.
- [x] **MLS-011:** Rust persisted-replay classification test.
- [x] **MLS-012:** Rust corrupted-ciphertext classification test.
- [x] **MLS-013:** Publish exact prerelease XCFramework tag.
- [x] **MLS-014:** Pin the published prerelease in the SDK.

### Pending-proposal bug

- [x] **MLS-015:** Audit callsites; only two internal wrappers exist and neither is called.
- [x] **MLS-016:** Call `clearPendingProposals` instead of `clearPendingCommit`.
- [x] **MLS-017:** Remove the unnecessary identity guard.
- [x] **MLS-018:** Run the Swift regression test that clears proposals.
- [x] **MLS-019:** Add pending-commit isolation coverage.
- [x] **MLS-020:** Add clear-proposal/clear-commit isolation cases to the MLS state suite.
- [x] **MLS-021:** Do not add a production migration without evidence of an active caller.

## M0.5 — Base64 transport migration

- [x] **B64-001:** Encode every new outbound E2EE byte field as standard padded base64.
- [x] **B64-002:** Send `X-Ermis-E2EE-Bytes: base64` on Bellboy HTTP requests.
- [x] **B64-003:** Send `e2ee_bytes=base64` during WebSocket connection.
- [x] **B64-004:** Decode canonical standard padded base64 for all current E2EE wire fields.
- [x] **B64-005:** Temporarily decode legacy JSON byte arrays for persisted/mixed-window input only.
- [x] **B64-006:** Never emit a new legacy JSON byte array.
- [x] **B64-007:** Cover HTTP selection and representative request bodies with runtime tests.
- [x] **B64-008:** Cover WebSocket selection with a runtime test.
- [x] **B64-009:** Canonicalize durable sync envelopes so array/base64 copies dedupe identically.
- [x] **B64-010:** Confirm product/staging/test keep `e2ee_byte_legacy=true` for the mixed-client window.
- [x] **B64-011:** Add privacy-safe inbound-legacy usage telemetry.
- [ ] **B64-012:** Remove the legacy decoder only after minimum-version and zero-usage gates.
- [x] **B64-013:** Keep the selector scoped to Bellboy `.normal` traffic; auth/sticker/external traffic is unchanged.
- [x] **B64-014:** Normalize only `mls_ciphertext` in old queued message bodies before replay; do not recursively rewrite attachment/custom fields.

## P0 tasks started but not yet gated

- [x] **STK-HOTFIX-001:** Encode new iOS encrypted sticker payloads with canonical `sticker_url`.
- [x] **STK-HOTFIX-002:** Decode both canonical `sticker_url` and legacy iOS `stickerUrl`, with
  canonical precedence when both are present.
- [x] **STK-HOTFIX-003:** Normalize legacy iOS sticker payloads at the Web SDK decrypt/archive
  boundary without retaining or re-emitting the camelCase alias.
- [x] **STK-HOTFIX-004:** Add iOS and Web regression coverage for both wire spellings and run the
  existing MLS/attachment/media repair suites.
- [x] **TIM-HOTFIX-001:** Populate each server message's Core Data sorting key before an
  in-transaction channel-preview fetch.
- [x] **TIM-HOTFIX-002:** Bind `ChannelDTO.previewMessage` to the authoritative newest valid
  message from the channel payload instead of leaving the previous relation stale.
- [x] **TIM-HOTFIX-003:** Resolve equal server timestamps by payload order while preserving a
  newer local pending preview that is not present in the server batch.
- [x] **TIM-HOTFIX-004:** Cover fresh-batch, equal-timestamp, and invalid-message preview cases
  with in-memory Core Data regression tests.
- [x] **UI-HOTFIX-001:** Require project-scoped current-user authorship before local edit,
  resend, or delete-for-everyone mutations.
- [x] **UI-HOTFIX-002:** Ignore stale local delivery/edit state when building actions for a
  foreign message, restoring Reply while withholding Edit/Delete/Resend.
- [x] **UI-HOTFIX-003:** Clear invalid foreign local mutation state when an authoritative message
  payload is saved.
- [x] **UI-HOTFIX-004:** Cover ownership/action-state repair with focused tests and pass the full
  simulator suite plus generic physical-iOS build.
- [x] **UI-HOTFIX-005:** Apply the authoritative ownership/action policy to the production app's
  custom `ErmisMessageActionsViewController`, which overrides the SDK base controller.
- [x] **UI-HOTFIX-006:** Restore the production controller's Reply action for foreign messages and
  verify stale cached ownership cannot expose Edit/Delete-for-everyone.
- [x] **UI-HOTFIX-007:** Render an undecrypted E2EE quoted parent as the localized encrypted-message
  placeholder instead of leaking a reused deleted-message placeholder.
- [x] **UI-HOTFIX-008:** Replace hard-coded reply/encrypted English labels with English/Vietnamese
  resources and make ErmisChatUI localization fall back to its own bundle.
- [x] **UI-HOTFIX-009:** Cover quoted-view reuse, empty content reset, and localization fallback
  with focused UI regression tests.

- [x] **DUR-012:** Application processing returns plaintext, AAD, and epoch without saving state.
- [x] **DUR-013:** Commit processing returns typed `ProcessedMessage` without an implicit state save.
- [x] **DUR-014:** Do not discard `ProcessedMessage` in the generic protocol wrapper.
- [x] **DUR-015:** Require an explicit application-message provider save.
- [x] **DUR-015A:** Use the dedicated deferred OpenMLS application processor so receiver secrets
  remain replayable on disk until plaintext persistence succeeds.
- **DUR-017 — N/A:** Bellboy has no active standalone-proposal producer; proposal persistence is not a release gate.
- [x] **OUT-005:** Save sender state immediately after legacy/AAD message creation.
- [x] **OUT-TXT-001:** Persist text-only E2EE ciphertext and epoch synchronously before POST.
- [x] **OUT-TXT-002:** Rebuild retries from the durable ciphertext/epoch without re-encrypting.
- [x] **OUT-TXT-003:** Recover an E2EE message left in `.sending` as `.pendingSend` instead of deleting it.
- [x] **OUT-TXT-004:** Widen the current Model 3 message epoch field to Int64 and pass Model 2 migration.
- [x] **OUT-TXT-005:** Add exact-intent redaction/base64 regression coverage.
- [x] **CUR-001:** Enforce account/scope/event uniqueness and reject same-ID/different-payload duplicates.
- [x] **CUR-002:** Persist canonical raw event envelopes before runtime apply.
- [x] **CUR-003:** Create a separate durable fetch cursor.
- [x] **CUR-004:** Create a separate durable apply cursor.
- [x] **CUR-005:** Persist the user-scoped removed cursor durably, with UserDefaults only as a migration mirror.
- [x] **CUR-006:** Persist one server page and its fetch cursor in one Core Data transaction.
- [x] **CUR-007:** Advance fetch cursor only after the complete page is durable.
- [x] **CUR-008:** Keep server `next_cursor` as fetch proof, never apply proof.
- [x] **CUR-010:** Apply durable inbox events in canonical order.
- [x] **CUR-011:** Advance apply cursor from the exact completed envelope.
- [x] **CUR-012:** Await sync metadata database writes before event completion.
- [x] **CUR-013:** Stop a scope after a protocol/apply failure and persist a repair issue.
- [x] **CUR-014:** Advance the removed cursor only after serialized MLS deletion and awaited Core Data cleanup.
- [x] **CUR-015:** Bound pending durable inbox rows per scope/account and emit structured warning/rejection telemetry without evicting MLS events.
- [x] **CUR-016:** Re-persisting the same page does not create duplicate inbox rows.
- [x] **CUR-017:** Replay unapplied durable events after database reopen before newly fetched events.
- [x] **CUR-HOTFIX-001:** Preserve Bellboy's exact `(created_at, kind rank, event_id)` order when
  durable events are replayed after relaunch.
- [x] **IN-001:** Load the canonical raw inbox event inside the serialized MLS queue.
- [x] **IN-002:** Process an application message without implicitly saving provider state.
- [ ] **IN-003–004:** Exact attachment/forward AAD and canonical metadata verification await M2 models.
- [x] **IN-005–008:** Persist plaintext first, save MLS state, record persistence proof, then mark applied.
- [x] **IN-009:** Bind cached plaintext recovery to the exact MLS ciphertext SHA-256.
- [ ] **IN-010–011:** Attachment AAD/manifest rendering rejection awaits M2 receive models.
- [x] **IN-012:** Categorize apply failures as durable repair issues.
- [x] **IN-013:** Preserve an existing decrypted cache when message-update re-decrypt fails.
- [x] **IN-014:** Treat the currently unprojected system-message variant as an explicit supported no-op.
- [x] **IN-HOTFIX-001:** Persist application decrypt repair proof and advance its apply cursor
  without blocking later protocol commits or outgoing sends.
- [x] **IN-HOTFIX-002:** On a failed realtime `message.new` decrypt, retain the encrypted local
  snapshot and request canonical scope-sync recovery for its MLS group instead of waiting for app
  relaunch.
- [x] **IN-HOTFIX-003:** Preserve Bellboy application message types as forward-compatible raw
  values; only `system` is a special plaintext sync event.
- [x] **IN-HOTFIX-004:** Decode `reply`, `signal`, `sticker`, `poll`, and future encrypted
  application variants as application events instead of blocking the entire MLS scope as
  `unsupportedEvent(type: "application")`.
- [x] **REC-006:** Replay commits only with an exact durable ciphertext-hash/target-epoch marker and epoch guard.
- **REC-007 — N/A:** Bellboy does not emit standalone proposal events; the reserved wire value becomes an explicit repair issue.
- [x] **REC-HOTFIX-001:** Classify a durable commit with `targetEpoch < localEpoch` as historical
  instead of a forward epoch gap, without replaying it into OpenMLS.
- [x] **REC-HOTFIX-002:** Atomically persist the historical commit proof/disposition, resolve its
  repair issue, mark the event applied, and advance the exact apply cursor.
- [x] **REC-HOTFIX-003:** Unblock the affected MLS scope after historical reconciliation while
  keeping `targetEpoch > localEpoch + 1` as a blocking repair condition.
- [x] **REC-HOTFIX-004:** Cover the complete epoch-action matrix, idempotent replay, canonical
  ordering, proof mismatch rollback, and Model 2 to Model 3 migration in the full SDK test suite.
- [x] **REC-001:** A failed raw-page transaction does not advance fetch/apply cursors, so the
  server page remains refetchable.
- [x] **REC-002:** A crash after deferred decrypt/plaintext work but before provider save reloads
  the previous receiver ratchet and decrypts the exact durable event again.
- [x] **REC-003:** A crash after provider save but before cursor finalization accepts only
  `MessageAlreadyConsumed` with exact local plaintext/ciphertext-hash proof.
- [x] **REC-004:** Consumed-secret without the exact cached ciphertext proof is not skipped and
  follows the existing categorized repair path.
- [x] **REC-005:** Invalid/malformed ciphertext remains distinct from consumed-secret recovery.
- [x] **REC-008:** A future epoch gap remains blocking unless exact processed proof exists.
- [x] **REC-009:** A stale/no-matching Welcome returns a typed error and does not blindly delete
  the current group; exact external-join receipt finalization requires account/device/event proof.
- [x] **REC-010:** Removed-scope cleanup advances only after serialized MLS deletion, while rejoin
  uses the current KeyPackage/external-join receipt rather than stale Welcome state.
- [ ] **OUT-001–015:** Complete durable outgoing network-intent state machine.
- [x] **OUT-011:** On Bellboy's exact application-message `epoch_stale` rejection, durably discard
  only the rejected intent, finish canonical scope sync to the server-required minimum epoch,
  then permit one replacement encryption.
- [ ] **OUT-012:** Preserve the logical message ID and attachment IDs across epoch-stale recovery.
  The message-ID/retry boundary is implemented below; attachment-ID integration coverage remains
  blocked on the M2 authenticated attachment lane.
- [x] **OUT-012A:** Preserve the logical message ID for the currently enabled text/edit lanes,
  persist the replacement ciphertext/epoch before retry, and fail closed after a second stale
  rejection instead of automatically looping.
- [x] **OUT-014:** Apply the same persist-before-POST ordering to E2EE message edits, invalidate
  the previous intent for each user-created edit generation, and replay only an exact durable
  ciphertext/epoch after relaunch.
- [x] **OUT-HOTFIX-001:** Move a pre-HTTP encryption failure from `.pendingSend` to
  `.sendingFailed` so it does not remain stranded until app relaunch.
- [x] **OUT-HOTFIX-002:** Do not decrypt or scope-repair the current device's own WebSocket echo
  when its pre-POST plaintext cache already exists; preserve decryption for the same user on a
  different device when no local cache exists.
- [x] **LIFE-001:** Resolve pre-login clients to in-memory storage and authenticated clients to user-scoped Core Data.
- [x] **LIFE-002:** Share MLS provider/device/cursor storage across main app, NSE, and Share Extension via App Group.
- [x] **LIFE-003:** Preserve Core Data, durable inbox, MLS groups, device ID, and cursors on default logout; add explicit purge.
- [x] **LIFE-004:** Detect marker-proven reinstall before SDK setup and clear all app-owned Keychain values.
- [x] **BOOT-001:** Replace overlapping external join/sync with Welcome-first pre-sync, serialized external join, and post-sync readiness barrier.
- [x] **BOOT-002:** Gate encrypted sends until the effective MLS group is ready and retain historical ciphertext as repairable placeholders.
- [ ] **DUR/STO/DEV remaining:** Complete crash-injection coverage and run simulator/device runtime gates with the installed OpenMLS XCFramework.

## Exact M0 remainder

- [ ] **Attachment-contract chain:** CON-005, CON-011, and CON-013 remain blocked on the M2
  manifest/frame-crypto implementation and its cross-platform vectors.
- [x] **Release-artifact chain:** `open-mls-ios` prerelease `0.1.0-m0.1` is published with
  committed SHA-256 checksums and OpenMLS source provenance; the SDK pins the exact remote tag and
  CI verifies its revision, checksums, required API surface, simulator test compilation, and
  physical-iOS build. Local development uses SwiftPM editable mode rather than a committed path.

## Later phases

- [ ] **M2 tasks:** ATT, PEN, SEC, CRY, PRE, API, UP, RET, and BIND groups.
- [ ] **M3 tasks:** DNL, STR, UI, INF, BG, and SHR groups.
- [ ] **M4 tasks:** FWD and FUI groups.
- [ ] **M5 tasks:** TCR, TMD, TNS, PER, and ROL groups.
- [ ] **M6 tasks:** DOC-001–020 and final Definition of Done.
- [ ] **TODO-M7 tasks:** TODO-PIN-001–018.

## Progress log

### 2026-08-07 — production — iOS session lifecycle and E2EE bootstrap

- Goal: force login after reinstall while preserving same-user decrypt state and history across normal logout.
- Code changed: added installation-marker/Keychain handling in the host app; automatic memory/user storage resolution, fail-closed legacy Core Data migration, App Group MLS/defaults, preserve/purge logout policies, public channel readiness, send gating, bounded existing-group sync, and serialized Web-style missing-group bootstrap in the SDK.
- Docs changed: updated Bellboy's canonical client lifecycle/external-join guide and E2EE flow progress log. No SQL, README, Postman, API payload, backend or PIN/archive artifacts changed.
- Design: only a matching legacy `CurrentUserDTO` may migrate into a user namespace. Missing-group commits are skipped until Welcome/external join; stale Welcome without the current KeyPackage is non-blocking. Post-join sync closes the transport/snapshot race but does not recover pre-join history.
- Performance: scope sync sends at most 20 scopes/request under Bellboy's existing 100-events/request bound; external-join provider mutations are serialized and same-user resume performs zero external joins.
- Verification: all touched Swift files pass `swiftc -parse`; a code-signing-disabled full device build passed for the SDK, app, NSE and Share Extension. `swift test` remains blocked in the standalone local `open-mls-ios` dependency before SDK test compilation because generated UniFFI C types/functions are unavailable to SwiftPM.
- Next: run the SDK XCTest host after repairing the standalone UniFFI SwiftPM binding, then exercise reinstall, same-user logout/login, multi-user isolation and 100-channel bootstrap on device.

### 2026-08-06 — production — M0/P0 first slice

- Goal: begin the approved iOS attachment/forward plan at the mandatory MLS correctness gate.
- Code changed:
  - OpenMLS/UniFFI now maps a persisted application-message replay to
    `MessageAlreadyConsumed` while malformed or AEAD-invalid ciphertext remains `InvalidMessage`.
  - OpenMLS debug builds return `AeadError` instead of asserting on invalid ciphertext.
  - iOS fixes `clearPendingProposal`, adds an AAD-aware persisted send primitive, stops saving the
    receiver ratchet inside the decode method, and adds a synchronous Core Data write boundary so
    plaintext is saved before provider state.
  - Added Rust and Swift regression-test sources.
- Docs changed: Bellboy attachment contract now defines one authenticated frame for an empty file
  and records the actual maximum plaintext under the default ciphertext cap.
- Design: Core Data and OpenMLS SQLite remain eventually consistent; replay plus the distinct
  consumed-message error closes the crash window between the two stores.
- Verification:
  - `cargo test -p openmls-uniffi` passed: 26 tests.
  - `./build_mobile.sh ios` rebuilt the generated Swift binding and both arm64 XCFramework slices.
  - The canonical iOS AAD encoder produced the Web vector hash
    `10478e38376e07f02e5f7618355d21fa30fe70fe8a826505269705565d910fac`.
  - `swift build ... --target ErmisChat` passed for arm64 iOS Simulator and arm64 iPhoneOS.
  - `swift build ... --build-tests` compiled the SDK test targets for arm64 iOS Simulator.
- Blockers:
  - SwiftPM can compile but not execute XCTest directly on iOS Simulator; runtime Swift wrapper
    cases remain unchecked until an Xcode test host is added.
  - The existing app scheme stops before SDK compilation because `IntentsExtension` has duplicate
    copy tasks for three `AppIntentVocabulary.plist` files. No app-project files were changed.
  - Durable checkpoint entities and event raw bytes are implemented but not connected to page
    insert/apply transactions, so M1 and all attachment phases remain blocked.
- Next: atomically persist each sync page plus fetch cursor, replay the durable inbox, advance the
  apply cursor only after the exact event succeeds, then add exact outgoing network intents.

### 2026-08-06 — production — iOS XCTest host and durable inbox transactions

- Goal: remove the M0 runtime-test blocker and implement the transactional storage primitive for
  fetch/apply cursor separation without prematurely changing the production sync path.
- Code changed:
  - Added a Swift Package Xcode test workspace path and executed the SDK tests on an iOS
    Simulator, independently of the app project's broken extension copy phase.
  - Added Swift regressions for corrupt ciphertext classification and bidirectional isolation of
    pending proposals versus pending commits.
  - Added `E2eeDurableInboxStore`: canonical raw envelopes, same-ID/different-payload rejection,
    atomic page + fetch-cursor writes, independent apply cursor, repair issues, and ordered replay
    reads.
  - Set the OpenMLS mobile build default to minimum iOS 15.0 for Rust and bundled C dependencies,
    then rebuilt and installed the device/simulator XCFramework slices.
- Verification:
  - 16 iOS Simulator XCTest cases passed: 7 durable-inbox transaction tests and 9 MLS/AAD tests.
  - Page failure rolls back earlier inserts and the fetch cursor in the same Core Data transaction.
  - `otool` reports device objects at iOS 15.0 and simulator objects at iOS 14.0/15.0; no object
    retains the accidental iOS 26.5 minimum.
  - The final SDK link/test run passed without the previous newer-iOS static-library warning.
  - `xcodebuild` for `generic/platform=iOS` passed with code signing disabled, confirming the
    physical-device architecture and iOS 15 deployment target.
- Runtime status: production `syncPage` still uses the legacy cursor path. The durable store is not
  wired until every event handler returns an awaited success/failure outcome; otherwise marking an
  async handler applied would recreate the cursor mismatch this phase is intended to eliminate.
- Artifacts: no Bellboy SQL or Postman changes are required; APIs and backend schema are unchanged.
- Next: make sync handlers throwing/awaited, persist page before enqueue, replay pending rows on
  launch, and advance apply cursor only after the exact handler plus MLS/Core Data writes succeed.

### 2026-08-06 — production — durable sync runtime and exact recovery proof

- Goal: switch production scope sync from the legacy fire-and-forget apply path to durable
  fetch/apply checkpoints without allowing a failed event to be skipped.
- Code changed:
  - `syncPage` now atomically persists every scope page and its authoritative fetch cursor before
    enqueueing any event. The server cursor is no longer used as apply proof and the timestamp +
    zero-UUID pagination fallback was removed.
  - App restart/database reopen loads unapplied canonical envelopes before new pages. Per-scope
    operations are deduplicated, ordered, and blocked at the first failure; successful handlers
    advance the apply cursor from the exact event envelope.
  - Reaction/delete/update/pin/member handlers now use awaited Core Data writes. Protocol commit
    application has idempotent epoch guards, verifies the resulting epoch, and treats the reserved
    proposal value, gaps, missing bytes, and unknown events as repairable blockers instead of
    silent success.
  - Foreground decrypt, edit re-decrypt, realtime protocol work, durable replay, and outgoing
    encrypt now share the per-group dependency chain. Outgoing encryption refuses to cross a
    blocked repair scope.
  - `MessageDecryptDTO` stores SHA-256 of the exact MLS ciphertext. A consumed-secret replay only
    finalizes from cached plaintext when this hash matches; a mismatch or legacy hashless cache
    remains pending for repair.
  - Added `ErmisChatModel 3` instead of mutating the shipped Model 2 schema. Model 3 adds the
    durable inbox/checkpoint/repair entities and the optional ciphertext proof hash, with inferred
    lightweight migration enabled for existing stores.
  - `removed_channels` pages now form a barrier across every affected group. OpenMLS deletion is
    completed first; cached channels, old scope inbox/checkpoint/repair rows, and the new removed
    cursor are then committed in one Core Data transaction. A failure leaves the cursor unchanged
    so the idempotent cleanup page is replayed rather than skipped.
- Verification:
  - Generic physical-iOS app integration build passed with code signing disabled.
  - 21 iOS Simulator XCTest cases passed: 12 durable-store/reopen/order/repair/migration/removal
    tests and 9 MLS/AAD tests. The suite includes a real Model 2 SQLite store opened and migrated
    by the current Model 3 container.
  - `git diff --check` and Swift parser checks passed.
- Performance/complexity: page durability is `O(K)` time and `O(total raw envelope bytes)` storage
  per page; apply remains sequential `O(K)` per MLS group. The change adds no network round trip.
  Contention remains bounded by the Core Data writer, the serialized MLS queue/provider, and disk
  I/O; attachment workers must not execute on this queue.
- Remaining M1 blockers: backlog bounds/telemetry, end-to-end crash injection,
  provider/device-ID migrations, and durable outgoing network intents.
- Artifacts: Bellboy API, SQL, and Postman are unchanged.

### 2026-08-06 — production — durable inbox backlog bounds

- Goal: prevent unbounded fetch/apply divergence from exhausting local storage without deleting
  protocol events that may be required to reconstruct MLS epoch state.
- Code changed:
  - `E2eeDurableInboxStore` warns at 1,000 pending events per scope or 5,000 per account and rejects
    a new page before insert/fetch-cursor advancement at 2,000 per scope or 10,000 per account.
  - A page whose canonical raw envelopes exceed 16 MiB is rejected atomically. Bellboy normally
    limits a page to 200 events, but a same-timestamp terminal bucket may exceed that limit; such a
    bucket is surfaced as an explicit repair blocker rather than truncated or partially persisted.
  - Existing duplicate envelopes are validated but excluded from projected backlog counts. Pending
    counts use Core Data count requests and do not load ciphertext blobs.
  - `E2eRepository` records categorized repair issues and emits structured `[E2eTelemetry]`
    warning/rejection records containing only scope/count/byte metadata. No plaintext, ciphertext,
    key, user identifier, or grant URL is logged.
- Failure behavior: a hard-limit or page-size rejection leaves both the page and fetch cursor
  unchanged. Already durable pending events can continue draining; the rejected page is retried on
  the next sync after the backlog falls below the hard limit.
- Verification:
  - 25 iOS Simulator XCTest cases passed: 16 durable-store/backlog/migration/removal tests and 9
    MLS/AAD tests.
  - Generic physical-iOS app integration build passed with code signing disabled.
  - Swift parser checks and `git diff --check` passed before this documentation-only update.
- Performance/complexity: validation and insertion remain `O(K)` per page. Each transaction adds
  two count queries; the account subset is bounded by the 10,000-row hard limit and no raw payload
  scan is required. Memory remains `O(K + raw response bytes already held by sync)`, accepted page
  bytes are capped at 16 MiB, and this change adds no network request. The Core Data writer remains
  the contention point; attachment crypto and transfer work must stay off the MLS chain.
- Remaining M1 blockers: end-to-end crash injection, provider/device-ID migrations, and durable
  outgoing network intents.
- Artifacts: Bellboy API, SQL, README, and Postman are unchanged. This Swift/Core Data slice does
  not alter UniFFI and does not require regenerated OpenMLS bindings.

### 2026-08-06 — production — exact commit replay proof

- Goal: close the crash window where a sync commit found the target epoch already active and was
  treated as applied without proving that the same durable event advanced OpenMLS.
- iOS runtime changed:
  - Every durable commit stores SHA-256 of the exact MLS commit bytes and its target epoch in Core
    Data before `processMessage`; mismatched hash/epoch is a categorized repair blocker.
  - OpenMLS commit processing is now typed and uses an explicit provider save. The completion
    marker is written only after the loaded group reaches exactly the target epoch and save
    succeeds; the exact event cursor advances afterward.
  - On relaunch after provider save but before the completion marker, recovery accepts an already
    active target epoch only when the proof existed before this apply attempt. A same-device
    commit may also reconcile by exact `device_id`; an unrelated remote epoch advance without a
    prior proof is rejected.
  - Realtime commit/external-commit delivery no longer mutates OpenMLS directly. It triggers scope
    sync so the raw envelope and commit proof are durable first. Welcome handling is unchanged.
- Verification:
  - 28 iOS Simulator XCTest cases passed: 18 durable-store/proof/migration/removal tests and 10
    MLS/AAD/protocol tests.
  - Generic physical-iOS app integration build passed with code signing disabled.
  - The binding-level commit test verifies typed `.commit`, exact `N -> N+1` transition before
    explicit save, and the same epoch after provider reload.
  - Swift parser, Core Data XML, and diff hygiene checks passed before this documentation update.
- Performance/complexity: one SHA-256 pass over the small commit message plus two `O(1)` Core Data
  proof writes are added per commit. Realtime delivery may add one scope-sync request; duplicate
  triggers are coalesced by the existing sync guard. No UniFFI regeneration is required for this
  slice because the typed commit result and explicit save APIs already exist in the installed
  binding.
- Remaining M1 blockers: crash injection for the remaining boundaries, provider/device-ID
  migrations, and durable outgoing network intents. Attachment and forward remain gated.
- Artifacts: Bellboy API, SQL, README, and Postman are unchanged.

### 2026-08-06 — correction — remove unused standalone proposal recovery

- Producer audit confirmed Bellboy emits commits directly and has no active `type=proposal`
  producer. The enum remains decodable only for wire compatibility.
- Removed processed-proposal reference binding, provider lookup, Core Data proof fields, runtime
  recovery logic, and proposal replay tests. An unexpected proposal event is persisted as an
  unsupported repair issue and cannot mutate MLS state or advance the apply cursor.
- Retained proposal-construction APIs and the `clearPendingProposal` regression/isolation tests;
  those validate the OpenMLS wrapper but are not a Bellboy production flow.
- Regenerated the Swift UniFFI source and both arm64 XCFramework slices because the exported
  binding surface changed.
- Verification: `cargo test -p openmls-uniffi` passed 26 tests; iOS Simulator passed 28 tests;
  the generic physical-iOS app integration build passed with code signing disabled; Core Data XML,
  Swift parsing, and diff hygiene passed.
- Bellboy API, SQL, README, and Postman are unchanged.

### 2026-08-06 — production — iOS base64-only E2EE transport

- Goal: remove the remaining iOS legacy JSON byte-array emission before attachment/forward work,
  while preserving upgrade safety for already persisted events and queued message bodies.
- iOS runtime changed:
  - Added a field-scoped E2EE codec. Every current outbound MLS byte field now emits canonical
    RFC 4648 standard padded base64; the global JSON encoder remains unchanged.
  - Bellboy HTTP requests select the base64 lane with `X-Ermis-E2EE-Bytes: base64`; WebSocket
    connect selects it with `e2ee_bytes=base64`. There is no outbound fallback to number arrays.
  - Inbound models temporarily dual-read canonical base64 and validated legacy arrays. Invalid,
    fractional, negative, or greater-than-255 legacy values and non-canonical base64 fail closed.
  - Durable inbox raw envelopes are canonicalized before persistence/deduplication. An older stored
    array envelope and a new base64 copy of the same event therefore remain one event.
  - Old offline message bodies are normalized at replay, but only their direct
    `message.mls_ciphertext`/`old_message.mls_ciphertext`; custom attachment fields are untouched.
  - Legacy reads emit sampled count-only `[E2eTelemetry] inbound_legacy_byte_array` observations.
    Dimensions are restricted to a fixed source and allowlisted schema field; payload bytes,
    identifiers, keys, and URLs cannot enter the metric.
- Verification:
  - Full iOS Simulator suite passed: 43 tests, 0 failures. The focused transport suite passed
    14 tests, 0 failures after the final normalizer scope-hardening and telemetry changes.
  - Generic arm64 physical-iOS app integration build passed with code signing disabled, including
    the main app, Share Extension, Notification Service Extension, and Intents Extension.
  - Golden vectors cover empty and padded base64; request tests cover KeyPackages, message
    ciphertext, external join, enable encryption, HTTP header, WebSocket selector, old queued
    body migration, and custom-field non-rewrite.
- Performance/complexity: conversion is `O(N)` time and temporary memory at the JSON boundary;
  base64 uses approximately `4/3` wire bytes instead of the substantially larger number-array
  representation. No network/DB round trip is added. Attachment file bytes stay on the binary
  upload path and are not base64-encoded into JSON.
- Compatibility: inbound legacy decode is migration-only and remains scheduled for removal behind
  minimum-version plus zero-usage gates. New TestFlight builds never emit legacy arrays.
- Artifacts: no SQL or OpenMLS/UniFFI change is required. Bellboy Postman already carries the
  selector and remains valid.

### 2026-08-07 — production — M0 authenticated-lane guard and iOS base64 selection

- Goal: close the locally actionable M0 AAD safety gaps and make new iOS traffic consistently
  select Bellboy's base64 lane before attachment/forward implementation.
- iOS runtime changed:
  - Added constant-time verification of the exact processed MLS AAD against the canonical envelope
    AAD, with a typed mismatch failure.
  - The legacy no-AAD E2EE sender now accepts only plain text. Attachment or forward metadata fails
    closed until M2/M4 supplies the authenticated sender.
  - The existing forward endpoint now executes only for a locally known standard destination.
    E2EE or unknown destinations fail closed, preventing a plaintext privacy downgrade.
- Bellboy rollout is unchanged: product, staging, and test remain `e2ee_byte_legacy=true` for
  older deployed client versions. New iOS always sends the base64 HTTP/WebSocket selectors and
  never emits legacy arrays. Its local legacy-array decoder remains temporarily for persisted and
  offline upgrade data.
- Verification:
  - `MlsPersistenceTests` passed 12 tests with zero failures, including AAD round-trip, exact AAD,
    tampered-envelope rejection, consumed-secret classification, corrupt-ciphertext separation,
    and legacy-lane metadata rejection.
  - Bellboy `cargo test util::serde` passed 17 serializer/selector tests with zero failures.
- Performance/complexity: sender routing adds one indexed local channel lookup and `O(1)` metadata
  checks. AAD verification is `O(A)` time for `A` authenticated bytes and constant auxiliary
  memory. There is no new network round trip, file I/O, or OpenMLS mutation.
- Remaining M0 blockers: CON-005/011/013 require M2 manifest/frame crypto; MLS-006/013/014 require
  committing, publishing, and pinning an exact `open-mls-ios` prerelease artifact. No UniFFI
  regeneration is required for this slice because the installed generated binding already exposes
  the required AAD and consumed-secret APIs.
- Artifacts: Bellboy SQL, README, and Postman are unchanged because endpoint/schema/example payload
  shapes did not change. Bellboy E2EE docs and the rollout cleanup plan were synchronized.

### 2026-08-07 — production — M1 text-only durable outgoing intent

- Goal: close the existing text-only E2EE crash window where OpenMLS sender state was durable but
  the exact ciphertext existed only in memory before POST.
- Runtime changed:
  - After OpenMLS `createMessage` and `saveState`, iOS synchronously persists the exact ciphertext,
    epoch, and own plaintext cache before changing the local message to `.sending` or starting HTTP.
  - A failed/unknown HTTP result and a relaunch reuse the persisted message ID, ciphertext, and
    epoch; the sender ratchet is not advanced again for that retry.
  - A message killed in `.sending` with a durable E2EE ciphertext returns to `.pendingSend` instead
    of being deleted. The legacy standard-message rescue behavior is unchanged.
  - Model 3 widens `MessageDTO.mlsEpoch` from Int16 to Int64 so the durable intent cannot overflow
    on a long-lived group; the already-published Model 2 remains untouched.
- Crash ordering: if the process dies after OpenMLS save but before the synchronous Core Data
  transaction commits, no exact intent exists and the next attempt creates a fresh generation. If
  the transaction committed, every later attempt reuses it. No POST is reachable before commit.
- Verification: full iOS Simulator suite passed 46/46, including exact-intent encoding/redaction
  and Model 2→3 lightweight migration. Generic arm64 physical-iOS app integration build passed
  with main app, Share Extension, NSE, and Intents Extension.
- Performance/complexity: first send adds one synchronous Core Data transaction with `O(C)` data
  copy/storage for ciphertext size `C`; retry is `O(C)` request encoding and performs no MLS crypto.
  There is no additional network round trip.
- Checklist scope: OUT-TXT-001–005 are complete. OUT-001–015 remain open as a group because the
  dedicated `PendingE2eeSend` record, AAD, attachments, epoch-stale rebinding, edit flow, and crash
  injection gates are not yet complete.
- Artifacts: Bellboy API/SQL/README/Postman are unchanged. Client-flow and implementation progress
  docs were updated; no UniFFI regeneration is required.

### 2026-08-07 — correction — Bellboy compatibility boundary

- Bellboy product/staging/test remain `e2ee_byte_legacy=true` for older deployed clients. The iOS
  base64 work changes only what new iOS emits/selects; it does not authorize a server hard cutover.
- The incorrect Bellboy config edits were fully restored and the related docs/checklist wording was
  corrected. No iOS code rollback is needed because new iOS is compatible with Bellboy's base64
  selector while the server continues serving legacy clients independently.

### 2026-08-07 — production hotfix — offline rotate recovery and stranded pending sends

- Reproduced the failure chain from code and screenshots: one durable application decrypt failure
  inserted the whole scope into `blockedDurableScopes`; subsequent commits were skipped and
  `encryptedMessage` rejected every new send for that group. The send worker then removed the
  failed request while its database row remained `.pendingSend`, so constructing a new worker on
  relaunch was the only thing that retried it.
- Runtime fixes:
  - Durable replay now uses Bellboy's exact ordering `(created_at, protocol/application/metadata,
    event_id)`. It no longer falls back to `(created_at,event_id)`, which could invert an
    application and commit sharing a timestamp after process death.
  - A regular application decrypt failure records a durable repair issue, retains the raw
    ciphertext/event and encrypted UI placeholder, advances the exact apply cursor with the
    failure category intact, and continues processing later events. Protocol/commit failures
    still block the scope because advancing past missing MLS state would be unsafe.
  - Encryption failures that occur before HTTP now transition the local bubble to
    `.sendingFailed`. Relaunch retry of an exact durable ciphertext remains enabled only for a
    send already in `.sending`, preserving the intended unknown-result crash recovery behavior.
- Verification: the focused durable-inbox suite passed 21/21 tests and the final full iOS
  Simulator suite passed 48/48. Added regressions for same-timestamp kind ordering, out-of-order
  apply rejection, and apply-cursor advancement that preserves repair evidence. The generic
  arm64 physical-iOS build also passed with code signing disabled.
- Performance/complexity: pending replay remains `O(K log K)` time. Each cursor advance decodes
  only the earliest equal-timestamp bucket for the secondary kind rank instead of re-decoding the
  whole backlog. No Core Data migration or extra network call is introduced; the maximum durable
  backlog remains bounded at 2,000 events/scope.
- Artifacts: iOS runtime/tests/progress ledger changed. Bellboy code, configuration, SQL, README,
  docs, and Postman were not modified. No OpenMLS/UniFFI binding regeneration is required.

### 2026-08-07 — production hotfix — realtime decrypt recovery without relaunch

- Verified failure chain: realtime `message.new` attempted MLS decrypt immediately, while realtime
  commit delivery only started asynchronous durable scope sync. If the application event arrived
  before the commit was fetched/applied, the decrypt callback discarded its error. Relaunch then
  appeared to fix the message because startup scope sync replayed protocol/application events in
  canonical order.
- Runtime fix: a successful realtime decrypt keeps the existing zero-round-trip fast path. A
  failed decrypt keeps the encrypted `MessageDTO` and requests targeted scope sync for the
  canonical MLS group/parent scope. Commit bytes are still processed only from the durable inbox;
  there is no timer retry and no direct WebSocket mutation path.
- Regression: `MlsPersistenceTests` verifies failure selects the canonical group recovery scope
  while success selects no recovery. The focused MLS suite and the full 49-test iOS Simulator
  suite passed; generic iOS/arm64 build passed with code signing disabled.
- Performance/complexity: successful realtime delivery remains `O(C)` MLS decrypt with no added
  network request. A failed decrypt adds at most the existing coalesced scope-sync request path;
  processing remains `O(K)` for `K` returned events with bounded durable-page memory. Multiple
  failures during an active sync collapse into the existing per-scope pending set.
- Artifacts: only iOS runtime, tests, and this progress ledger changed. Bellboy API, runtime,
  configuration, SQL, README, docs, and Postman remain untouched. No UniFFI regeneration is needed.

### 2026-08-07 — production correction — sequential sender encryption after own echo

- User clarification: the regression was on iOS outgoing encryption—message 1 sent, while later
  messages failed—not receiver-side rendering. A binding-level test confirmed three sequential
  `createMessage -> saveState -> reload` generations encrypt and decrypt correctly, ruling out an
  OpenMLS sender-ratchet persistence failure.
- Root cause in iOS orchestration: the preceding realtime-recovery hotfix also treated the current
  device's own `message.new` WebSocket echo as an incoming decrypt candidate. MLS deliberately
  rejects decrypting one's own ciphertext, so that expected error incorrectly started scope
  recovery and could put following sends behind an unrelated durable repair path.
- Runtime correction: if a realtime message is authored by the current user and already has the
  pre-POST local plaintext cache, it is an own-device acknowledgement and bypasses MLS decrypt and
  recovery. A same-user message from another device has no local cache and still follows normal
  decryption.
- Verification: MLS focused suite passed 15/15, including three sequential persisted sender
  generations and own-echo routing. Full iOS Simulator suite passed 51/51; generic iOS/arm64 build
  passed with code signing disabled; `git diff --check` passed.
- Performance/complexity: own-echo classification is `O(1)` and removes one failed MLS operation
  plus a scope-sync round trip per locally sent message. Normal incoming and outgoing crypto costs
  are unchanged.
- Artifacts: iOS runtime/tests/progress ledger changed. Bellboy API/runtime/configuration, SQL,
  README, docs, and Postman remain untouched. No OpenMLS/UniFFI regeneration is required.

### 2026-08-07 — interoperability hotfix — encrypted sticker key normalization

- Root cause: iOS used synthesized Codable key `stickerUrl` inside the MLS-encrypted JSON payload,
  while the Bellboy/Web cross-platform contract uses `sticker_url`. MLS decryption itself
  succeeded, but the receiving client could not project the sticker metadata and rendered the
  encrypted-message placeholder.
- Runtime fix:
  - New iOS ciphertext always contains canonical `sticker_url`; the outer Bellboy envelope still
    clears its sticker field and therefore does not expose the URL outside MLS ciphertext.
  - iOS reads canonical `sticker_url` and the decode-only legacy `stickerUrl` alias so old iOS
    ciphertext remains readable. Canonical data wins if both keys are present.
  - Web normalizes the legacy alias immediately after live or epoch-archive decryption, removes the
    camelCase property, and retains its existing canonical outbound format.
- Verification: iOS added four payload compatibility tests and the full iOS Simulator suite
  passed 55/55; generic iOS/arm64 build passed with code signing disabled. Web SDK build/type
  generation passed; payload compatibility passed 2/2, repair 21/21, attachment 12/12, and media
  streaming 12/12.
- Compatibility/performance: normalization is `O(1)` per decrypted message and introduces no
  network, storage migration, or crypto change. Already-sent legacy ciphertext is recoverable when
  replayed/decrypted by either updated client.
- Artifacts: iOS SDK, Web SDK, their tests, and this ledger changed. Bellboy runtime,
  configuration, API, SQL, README, docs, and Postman remain untouched. No OpenMLS/UniFFI binding
  regeneration is required.

### 2026-08-07 — production hotfix — channel timeline latest-message projection

- Root cause: channel payload upsert selected `previewMessage` inside the same Core Data
  transaction that inserted the latest messages. Their `defaultSortingKey` was populated only by
  `MessageDTO.willSave()`, which runs after the preview fetch, so a previously persisted message
  with a non-null key could remain the channel-list preview even though the timeline contained
  newer messages.
- Runtime fix:
  - Server messages now receive their sorting key immediately after authoritative timestamps are
    applied, before any same-transaction preview query.
  - Channel payload persistence tracks the saved message objects and promotes the authoritative
    newest eligible payload message. Equal timestamps follow Bellboy's chronological payload
    order; ephemeral/error/deleted/shadowed/ineligible messages still use the existing preview
    predicate, and a newer local pending preview outside the server batch is preserved.
  - `needsPreviewUpdate` now treats a different message at an equal timestamp as a candidate,
    preventing the relation from staying on the preceding message.
- Verification: focused channel-preview persistence suite passed 3/3. Full iOS Simulator suite
  passed 58/58 with zero failures/skips, generic iOS/arm64 build passed with code signing disabled,
  and `git diff --check` passed.
- Performance/complexity: channel payload persistence remains `O(K)` time for `K` latest messages
  plus the existing bounded Core Data preview fetch. It adds `O(K)` temporary ID mapping (normally
  bounded by the configured latest-message limit), no network/database round trip, no MLS work,
  and no schema migration. Contention remains on the existing Core Data writer transaction.
- Artifacts: iOS persistence code, regression tests, checklist, and this progress ledger changed.
  Bellboy API/runtime/configuration, SQL, README, docs, and Postman were not changed because the
  server contract and response ordering are unchanged. No OpenMLS/UniFFI regeneration is needed.

### 2026-08-07 — diagnostics — correlated E2EE encrypt/send trace

- Completed tasks:
  - [x] **OBS-SEND-001:** Add one privacy-safe trace context correlated by local `message_id` and
    channel/group scope across the complete outbound E2EE pipeline.
  - [x] **OBS-SEND-002:** Instrument MLS queue wait, group load, `createMessage`, and OpenMLS
    `saveState` as distinct stages with epoch, byte counts, and elapsed time.
  - [x] **OBS-SEND-003:** Instrument durable intent reuse/persistence, local message-state writes,
    HTTP start/result, authoritative response persistence, and terminal failure-state writes.
  - [x] **OBS-SEND-004:** Map failures to stable type/domain/code plus Bellboy HTTP/API codes
    without recording error descriptions or response bodies.
  - [x] **OBS-SEND-005:** Add regression coverage proving trace lines exclude plaintext,
    ciphertext values, AAD, URLs, and server error messages.
- Runtime usage: filter device/Xcode Console logs by `[E2EE_SEND]`; then filter the failing
  bubble's `message_id`. The last `stage=` identifies whether the failure occurred before MLS,
  while waiting for the group queue, during `createMessage`, during OpenMLS state persistence,
  during exact-intent persistence, in the HTTP request, or while reconciling local state.
- Verification: the dedicated trace suite passed 3/3. The final full iOS Simulator suite passed
  61/61 with zero failures/skips, generic iOS/arm64 build passed with code signing disabled, and
  `git diff --check` passed.
- Security/performance: log construction is `O(1)` per stage and records only identifiers,
  counters, epochs, timings, and stable numeric error metadata. It never records message text,
  ciphertext bytes, AAD, keys, sticker/attachment/grant URLs, error descriptions, or response
  bodies. There is no network call, schema migration, or crypto-format change.
- Artifacts: iOS runtime, tests, and this progress ledger changed. Bellboy API/runtime/config,
  SQL, README, docs, and Postman remain untouched. No OpenMLS/UniFFI binding regeneration is
  required.

### 2026-08-07 — production hotfix — stale durable commit repair gate

- Reproduced state: the OpenMLS provider was already at epoch 4 while the oldest unapplied
  durable commit targeted epoch 2. The previous guard treated every non-adjacent target as a
  forward gap, inserted the channel into `blockedDurableScopes`, and rejected later sends at
  `mls_group_blocked_by_repair` before encryption.
- Runtime correction uses an explicit epoch matrix:
  - `target < local`: finalize the event as historical/superseded; never mutate OpenMLS.
  - `target == local`: use the existing exact-proof/own-device replay path.
  - `target == local + 1`: process and persist the next commit normally.
  - `target > local + 1`: retain the blocking repair issue because protocol history is missing.
- Historical finalization is one synchronous Core Data transaction. It verifies the canonical raw
  envelope and ciphertext hash/target epoch, preserves canonical pending-event order, records
  `protocol_superseded`, resolves matching repair issues, marks the event applied, and advances
  the exact apply cursor. Replaying the same event is idempotent; a proof mismatch rolls back the
  transaction and remains blocked.
- Recovery behavior: the next normal/startup scope sync replays the durable event, emits
  `Superseded historical commit ... target_epoch=2 local_epoch=4`, clears the in-memory scope
  block, and allows the existing outbound queue to reach MLS encryption again. No database wipe,
  group rejoin, or user action is required.
- Verification: full iOS Simulator suite passed 69/69 with zero failures, including epoch matrix,
  atomic supersede, ordering, idempotency, proof-mismatch rollback, and Model 2 migration. Generic
  iOS/arm64 build passed with code signing disabled; `git diff --check` passed.
- Complexity: classification is `O(1)` and historical finalization adds one existing Core Data
  writer transaction, with no network request and no crypto operation. No new Core Data model
  version is required because existing proof/status fields represent the terminal disposition.
- Artifacts: only iOS runtime, tests, checklist, and this progress ledger changed for this hotfix.
  Bellboy API/runtime/configuration, SQL, README, docs, and Postman remain unchanged. No
  OpenMLS/UniFFI binding regeneration is required.

### 2026-08-07 — production hotfix — application subtype repair gate

- Production evidence isolated the channel-specific difference. The failing team scope stopped at
  event `d0f0a0ef-71f7-4a2e-b2fa-1edb2fb55b6a` with
  `unsupportedEvent(type: "application")`, then every send stopped at
  `mls_group_blocked_by_repair`. In the same session, a direct-message scope completed group load,
  MLS encryption/state persistence, durable intent persistence, HTTP 200, and response
  reconciliation.
- Root cause: the iOS scope-sync payload restricted Bellboy's application `type` to only
  `regular` and `system`. Bellboy also emits `reply`, `signal`, `sticker`, and `poll`; decoding any
  of those values failed and the outer tolerant event decoder incorrectly downgraded the otherwise
  valid event to unknown application data, which is a blocking protocol-scope condition.
- Runtime correction keeps the application subtype as a raw string. Only `system` follows the
  plaintext supported-no-op path; every other subtype remains an encrypted application event and
  therefore uses normal decrypt/application-repair semantics without poisoning the MLS protocol
  scope. This is forward-compatible with future Bellboy application subtypes.
- Recovery behavior: the canonical raw envelope was already durable. On the next startup or scope
  sync, pending replay decodes that same row with the corrected model, clears the transient scope
  block for retry, and either applies the plaintext normally or records the existing non-blocking
  application repair proof. No database wipe, group rejoin, cursor rewrite, or user action is
  required.
- Verification: focused subtype coverage passed 3/3 for `regular`, `reply`, `signal`, `sticker`,
  `poll`, an unknown future value, `system`, and a missing-type default. The full iOS Simulator
  suite passed 72/72 with zero failures. Generic iOS/arm64 build passed with code signing disabled;
  `git diff --check` passed.
- Complexity: message-type classification remains `O(1)` and adds no database transaction,
  network request, allocation proportional to message size, or crypto operation. No storage/API
  migration is required.
- Artifacts: only iOS payload decoding, regression tests, checklist, and this progress ledger
  changed for this hotfix. Bellboy API/runtime/configuration, SQL, README, docs, and Postman remain
  unchanged. No OpenMLS/UniFFI binding regeneration is required.

### 2026-08-07 — production fix — fresh-login typed errors and historical join boundary

- Root causes:
  - `WelcomeError::NoMatchingKeyPackage` was flattened to `InternalError`; iOS then identified it
    by text and retried the same Welcome after deleting the group.
  - MLS used App Group defaults while HTTP/auth still read `UserDefaults.standard`, so an own
    external commit could carry a different device ID and fail same-epoch proof.
  - Fresh-device history had no durable first-decryptable epoch, so pre-join ciphertext entered
    OpenMLS and accumulated repeated `TooDistantInThePast` repair rows.
- Bridge/runtime changes:
  - Appended typed `MlsError.NoMatchingKeyPackage` in Rust/UDL, regenerated the Swift binding and
    XCFramework, and removed delete/retry from `MlsClient.joinWithWelcome`.
  - Added one user-scoped `MlsDeviceIdStore` shared by MLS, request encoders, WebSocket auth and
    authentication. A differing standard-default ID is receive-only legacy alias for that user.
  - Added Core Data Model 4 fields for `mlsFirstDecryptableEpoch`, application disposition and
    durable external-join receipts. Receipts progress through `prepared`, `serverAccepted`,
    `merged`, then are deleted only after the exact post-sync external-commit event advances.
  - Same-epoch commit finalization now requires an event proof, exact join receipt, or current-user
    canonical/legacy device proof. Welcome/verified own join events may backfill a missing first
    epoch; current provider epoch alone never does.
  - Application epochs before the verified join boundary become `pre_join_historical` atomically
    with cursor movement, preserving raw ciphertext and UI placeholders with zero OpenMLS calls.
    Consecutive historical runs are grouped at up to 100 events per Core Data transaction.
    Missing-group events become `pending_group` and are retried after the join. Existing repair
    rows below the boundary are normalized/resolved without deleting timeline data.
- Readiness hardening: post-sync returns `needsRetry` while a merged join receipt remains; send is
  opened only after the exact external-commit event crosses the durable apply cursor and the
  receipt is finalized/deleted.
- Crash recovery: `serverAccepted` resumes and merges the persisted pending group; `merged`
  continues post-sync; an unproven `prepared` attempt is cleared and rebuilt from current
  GroupInfo. Hash/epoch/account/device mismatch remains scope-blocking.
- Verification:
  - Rust typed-error integration test passed.
  - `./build_mobile.sh ios` regenerated both iOS archives/XCFramework successfully.
  - Generic iOS Simulator build succeeded with Core Data Model 4 compilation.
  - Full iOS Simulator suite passed 88/88 after the runtime/schema changes. A final dedicated
    device-identity suite passed 3/3 after adding the cross-path assertion that MLS, HTTP and
    WebSocket all emit the same canonical ID.
  - Focused coverage includes enum transport/no-delete behavior, device-ID migration/alias
    isolation, application epoch matrix, historical batch cursor movement, join receipt crash
    finalization, legacy repair normalization and Model 2-to-current lightweight migration.
- Performance/complexity: pre-join classification and normalization are `O(H)` with zero MLS
  decrypts; consecutive runs need at most `O(H/100)` Core Data writer transactions, fetches use
  batch size 100, and the durable page remains capped at 16 MiB.
  No Bellboy network request, SQL schema, API, README or Postman artifact changed. External join
  remains globally serialized and existing scope limits remain 20 scopes/100 events.

### 2026-08-07 — production fix — multi-user bootstrap send safety and exact durable boundary

- Root cause: a merged external-join receipt was treated as a general “not ready” condition. This
  conflated a crypto-safe local provider with unfinished scope-sync reconciliation, so a new user
  could receive/decrypt on an old channel but every outbound attempt failed locally with
  `E2eeChannelNotReady`. Direct page processing also allowed a newly inserted scope-sync event to
  race an older durable pending prefix; malformed `message_pin` used an obsolete in-data CID shape
  and could poison the same scope.
- Runtime correction:
  - `encryptedMessage` now has an internal crypto-safety gate. A restored group is allowed unless
    there is a protocol blocker; an external join is allowed immediately after `merged` only when
    receipt status, SHA-256 commit hash, epoch, account and canonical request device ID match the
    locally persisted group epoch. `prepared`, `serverAccepted`, group/provider failure, epoch gap,
    or exact proof mismatch remain hard blockers. Public `E2eeChannelReadiness` remains a
    lifecycle/sync state and is not a breaking API change.
  - Scope sync no longer processes `persisted.insertedEvents` directly. One bounded (100-event)
    durable-prefix scheduler services startup, page, retry and WebSocket-triggered work per scope;
    it keeps Bellboy `(created_at, kind rank, event_id)` order and only protocol failures block the
    prefix. Invite hints received inside `pre-sync -> join -> post-sync` coalesce to one catch-up.
  - Core Data Model 5 adds optional exact join-boundary timestamp/event-ID fields without changing
    Model 4. Exact own `external_commit` now advances the cursor, writes the boundary, finalizes the
    matching receipt and resolves its repair in one transaction. Events before that boundary are
    `pre_join_historical` even at the same or absent epoch; a merged receipt before its exact event
    buffers application envelopes as `pending_group`.
  - `message_pin` now decodes Bellboy's `{action,message,sender,created_at}` using the outer scope
    CID; legacy durable `user` remains decode-only. Known metadata errors create metadata repair
    records and advance their exact cursor without blocking send. Own scope-sync application echoes
    are skipped only after exact message-ID + ciphertext + persisted plaintext proof, never merely
    by user ID.
- Backend assumption verified against `external_join_handler`: Bellboy validates the requested
  epoch and persists `commit_mls_transition` before returning HTTP success. If that atomicity ever
  changes, the merged-receipt send policy must return to hard-block until post-sync proof.
- Verification: Swift parser passed for all modified iOS sources and focused boundary classifier
  tests were added. SwiftPM test execution reached the existing standalone `open-mls-ios` build
  failure (missing generated UniFFI C symbols) before `ErmisChat` test compilation, so no runtime
  test count is claimed for this change.
- Artifacts: iOS SDK/model/tests plus Bellboy client guide and flow documentation changed. Bellboy
  runtime/API/SQL/README/Postman and PIN/archive remain unchanged because the wire contract did not
  change.

### 2026-08-07 — production — plaintext-first receiver crash recovery

- Audit correction: current OpenMLS eagerly writes the mutated message-secret tree from
  `unprotect_message` to preserve forward secrecy. The previous UniFFI comment claiming that
  application processing remained unpersisted until `saveState` was therefore false, leaving a
  crash window between decrypt return and the Core Data plaintext transaction.
- OpenMLS/binding change: added an opt-in `process_message_deferred` path. The normal
  `process_message` behavior is unchanged. Deferred processing mutates only the loaded group;
  dropping it before `save_state` reloads the prior durable receiver ratchet, while saving after
  the app transaction consumes the secret durably. Swift bindings and the iOS 15 device/simulator
  XCFramework slices were regenerated and installed into the separate `open-mls-ios` package.
- iOS runtime change: application decrypt now uses `processMessageDeferred`; Core Data persists
  plaintext plus exact ciphertext SHA-256 first, then the SDK calls `saveState`, then the durable
  inbox records MLS persistence and advances the exact event cursor. Protocol processing retains
  the existing eager path.
- Recovery proof: extracted the consumed-message classifier so only
  `MessageAlreadyConsumed + exact ciphertext hash` may finalize cached plaintext. Invalid
  ciphertext, a missing proof, or a mismatched hash still fails into categorized repair.
- External-join test correction: the stale fixture now follows the production transition
  `prepared -> serverAccepted -> merged -> finalized` and requires an exact `external_commit`
  account/device/epoch proof before writing the first-decryptable cursor.
- Verification:
  - `cargo test -p openmls-uniffi`: 28/28 passed.
  - Focused iOS recovery suite: 5/5 passed.
  - Full iOS Simulator SDK suite: 96/96 passed with zero failures/skips.
  - Generic iOS arm64 build passed with code signing disabled.
  - `git diff --check` passed after generated-header whitespace normalization.
- Performance/security: the deferred window is bounded to one serialized application operation
  and ends immediately after the synchronous Core Data write. Normal OpenMLS callers keep eager
  secret deletion. Exact replay proof adds one `O(ciphertextBytes)` SHA-256 only on the consumed
  recovery path and constant auxiliary memory; no network request or Core Data model migration was
  added.
- Artifacts: OpenMLS core/UniFFI tests and integration guide, the separate `open-mls-ios`
  generated binding/XCFramework, iOS runtime/tests, checklist, and this progress log changed.
  Bellboy runtime, docs, API, SQL, README, Postman, and PIN/archive artifacts were not modified.

### 2026-08-07 — production — durable E2EE edit network intent

- Gap closed: `MessageEditor` previously encrypted every retry in memory, so a failed request or
  relaunch could advance the sender ratchet again and POST a different ciphertext for the same
  edit. A process killed while `.syncing` also had no deterministic recovery policy.
- Runtime change:
  - A new user edit invalidates ciphertext, epoch, and ciphertext proof from the previous edit
    generation while keeping the edited plaintext cache.
  - The worker snapshots one pending edit generation, reuses an existing exact intent when
    present, or encrypts once and then synchronously persists ciphertext/epoch before `.syncing`
    and before HTTP POST.
  - The persistence transaction verifies the message is still `.pendingSync` and that plaintext,
    attachments, and sticker payload still match the snapshot. A concurrent newer edit therefore
    cannot send stale content.
  - Relaunch changes an E2EE `.syncing` edit with durable ciphertext back to `.pendingSync` without
    changing its intent. A syncing edit without durable intent fails closed as `.syncingFailed`.
  - E2EE attachment/forward edits remain fail-closed until their authenticated M2/M4 lane exists.
- Verification:
  - Focused E2EE edit persistence suite: 3/3 passed.
  - Full iOS Simulator SDK suite: 99/99 passed with zero failures/skips.
  - Generic physical-iOS arm64 build passed with code signing disabled.
  - `swift build --build-tests` and `git diff --check` passed.
- Artifacts: iOS runtime, tests, checklist, and this progress ledger changed. Bellboy runtime,
  configuration, API, SQL, README, docs, and Postman were not modified. No OpenMLS/UniFFI binding
  regeneration is required for this SDK-only state-machine change.

### 2026-08-07 — production — authoritative epoch-stale sync and one-shot re-encryption

- Contract boundary: recovery accepts only Bellboy's application send/edit rejection
  `epoch_stale: message encrypted with epoch <rejected>, current group epoch is <current>` on HTTP
  400/409. Protocol-transition epoch errors, malformed messages, non-client statuses, a rejection
  for another durable intent, and a server epoch that did not move forward cannot invalidate the
  stored ciphertext.
- Send/edit runtime:
  - The first exact rejection atomically clears only that rejected ciphertext/proof, stores the
    authoritative minimum epoch, and moves the row into a distinct durable recovery state.
  - Canonical MLS-scope sync must finish its pagination and serialized apply barrier. The SDK then
    reloads the group, verifies `localEpoch >= requiredEpoch`, and rechecks encrypt readiness before
    creating a replacement.
  - The replacement keeps the same message ID and request metadata, is encrypted once, and its
    exact ciphertext/epoch is persisted before the retry POST. End-to-end attachment-ID coverage
    remains unchecked under OUT-012 until the authenticated attachment lane is connected in M2.
  - Separate post-recovery in-flight states preserve the one-retry boundary across process death.
    Relaunch retries the exact replacement intent; a second stale rejection becomes a normal failed
    send/edit and never starts another automatic sync/re-encrypt loop.
  - Unknown HTTP/network results continue to retain and replay the exact durable intent. Only the
    exact authoritative stale response authorizes replacing it.
- Verification:
  - Focused epoch-stale recovery suite: 9/9 passed, including exact classifier, mismatched intent,
    send/edit transitions, relaunch recovery, worker rediscovery, and second-rejection loop guard.
  - Full iOS Simulator SDK suite: 108/108 passed with zero failures/skips.
  - Generic physical-iOS arm64 build passed with code signing disabled.
  - `git diff --check` passed.
- Artifacts: only iOS SDK runtime, tests, checklist, and this progress ledger changed. Bellboy
  runtime/configuration/API/docs/SQL/README/Postman remain untouched. OpenMLS has no API change, so
  UniFFI bindings and the separate `open-mls-ios` XCFramework were not regenerated.

### 2026-08-07 — production hotfix — message-action ownership and Reply restoration

- Root cause: the database mutation guard checked only that a current user and message existed;
  it never verified that the message author was that current user. A rejected foreign edit then
  left `.syncingFailed` on the row, and the action menu treated every failed row as a local
  mutation, exposing Edit/Delete while bypassing the normal Reply actions.
- Runtime fix:
  - Edit, resend, and delete-for-everyone now fail closed unless the message author matches the
    active current user for the message's project.
  - Foreign messages ignore stale local mutation state for UI interaction/action selection, so
    they use the normal Reply/Copy/Forward lane and never the Edit/Delete/Resend failure lane.
  - An authoritative foreign message payload clears invalid local mutation and hard-delete state,
    repairing rows produced by older clients.
  - Delete-for-me remains available for foreign messages and cannot be converted into a local-only
    hard delete by corrupt local state.
- Verification:
  - Focused message-action ownership suite: 4/4 passed.
  - Full iOS Simulator SDK suite: 112/112 passed with zero failures/skips.
  - Generic physical-iOS arm64 `ErmisChatUI` build passed with code signing disabled.
  - `git diff --check` passed.
- Complexity/security: all new ownership/action checks are `O(1)` and add no network, crypto, or
  persistence migration. Authorization is now enforced below the UI as well as reflected in it.
- Artifacts: only iOS SDK runtime/UI, tests, package test dependency, checklist, and this progress
  ledger changed. Bellboy runtime/API/docs/SQL/README/Postman and OpenMLS/UniFFI artifacts remain
  untouched because neither wire contract nor cryptographic binding changed.

### 2026-08-07 — production hotfix follow-up — app action-controller override

- Root cause: the production app registers its own `ErmisMessageActionsViewController`, so its
  action builder completely replaces the SDK base implementation. The override still switched on
  raw `message.localState` and trusted cached `isSentByCurrentUser`; therefore the SDK-only fix did
  not affect the menu shown in the app.
- Runtime fix:
  - The SDK exposes one project-scoped author/current-user ownership policy for action builders.
  - Both the SDK base controller and the production override use that policy and ignore local
    mutation state for foreign messages.
  - The production override now restores thread Reply when the channel capability permits it, in
    addition to the existing inline reply path. Edit and delete-for-everyone remain owner-only.
  - Existing foreign rows do not require a database resync for this UI repair because ownership is
    re-evaluated whenever the action menu is built.
- Verification:
  - Focused message-action ownership suite: 4/4 passed, including a deliberately stale cached
    ownership flag on a foreign `.syncingFailed` message.
  - Full iOS Simulator SDK suite: 112/112 passed with zero failures/skips.
  - Production `ErmisChatiOS` arm64 Simulator target build passed with code signing disabled.
- Complexity/security: ownership resolution and action filtering remain `O(1)`. This follow-up has
  no network, storage, crypto, API, or schema change.
- Artifacts: iOS SDK shared UI policy/tests/progress ledger and the production app action override
  changed. Bellboy, OpenMLS/UniFFI, SQL, Postman, and README artifacts remain untouched.

### 2026-08-07 — production hotfix — encrypted quoted-parent rendering and localization

- Root cause: `QuotedMessageView` had no explicit branch for an existing encrypted parent whose
  text and attachments were still unavailable. It hid the attachment preview but did not reset the
  reused text view, so a previous cell's localized deleted-message placeholder remained visible.
  The reply description and two encrypted-message preview paths also bypassed localization with
  hard-coded English strings. Finally, ErmisChatUI's generated lookup only consulted the injected
  Shared/app provider and did not fall back to the ErmisChatUI resource bundle for SDK-owned keys.
- Runtime fix:
  - An existing `ChatMessage` with encrypted bytes now renders `message.encrypted-message`; only a
    genuinely deleted or missing quoted model renders `message.deleted-message-placeholder`.
  - Empty non-encrypted quoted content clears reused attributed text explicitly.
  - Reply descriptions now use `Replied to you` / `Replied to %@` and their Vietnamese equivalents.
  - Timeline and channel-list encrypted placeholders use the same localized SDK key.
  - Generated localization preserves host-app overrides first, then falls back to the ErmisChatUI
    bundle. Missing English encryption keys were restored so regeneration preserves the public
    `L10n.Encryption` surface.
- Verification:
  - Focused quoted-message view suite: 3/3 passed, including deleted-to-encrypted cell reuse.
  - Full iOS Simulator SDK suite: 115/115 passed with zero failures/skips.
  - Production `ErmisChatiOS` arm64 Simulator target build passed with code signing disabled.
  - `git diff --check` passed.
- Complexity: rendering and localization lookup remain `O(1)` time and memory with no network,
  database, or crypto work added.
- Artifacts: ErmisChatUI rendering, localization resources/generated accessors, regression tests,
  and this progress ledger changed. Bellboy contracts/runtime, SQL, Postman, README, OpenMLS, and
  UniFFI remain unchanged because this is a client-only presentation fix.

### 2026-08-07 — production — exact OpenMLS iOS prerelease and compatibility gate

- Release boundary:
  - Published `open-mls-ios` tag `0.1.0-m0.1` at commit
    `1479aad14ab85bce7f884c1dd1dfa42006ed9834`.
  - The package records OpenMLS provenance at
    `10c4041392284a21ab019bdd942928faea5e3576`, minimum iOS 15, both arm64 slices,
    and SHA-256 for generated Swift, headers, module maps, and static libraries.
  - Required P0 APIs are enforced: AAD message creation, deferred application processing,
    explicit state save, consumed-secret classification, and typed `NoMatchingKeyPackage`.
    Epoch Archive/PIN remains deliberately absent from the UniFFI surface until TODO-M7.
- SDK/CI integration:
  - Replaced the committed local `../open-mls-ios` dependency with the exact remote prerelease.
  - Added a compatibility verifier that checks the resolved commit, release metadata, artifact
    checksums, Swift API declarations, and native FFI symbols.
  - Added CI cross-build gates for iOS 15 Apple Silicon Simulator, including test-target
    compilation, and physical iOS arm64. Private sibling dependency access uses the scoped
    `ERMIS_IOS_DEPENDENCY_TOKEN`; local OpenMLS work uses SwiftPM editable mode.
- Reproducibility:
  - The OpenMLS mobile build now normalizes generated C-header whitespace before XCFramework
    packaging. Rebuilding from the recorded source revision matches the published Swift source,
    headers, and static libraries byte-for-byte.
- Verification:
  - `cargo test -p openmls-uniffi`: 28/28 passed.
  - `./build_mobile.sh ios`: device and simulator XCFramework slices succeeded.
  - Published-checkout compatibility verifier passed for exact tag `0.1.0-m0.1`.
  - Full SDK simulator cross-build with all test targets passed.
  - Full SDK physical-iOS arm64 cross-build passed.
  - YAML/JSON validation and `git diff --check` passed.
- Complexity/operations: verification is `O(A)` in committed artifact bytes, currently about
  90 MiB across the two static libraries, with constant network round trips per package resolve.
  It adds no runtime CPU, memory, database, or Bellboy traffic. The main operational risk is
  private-repository credential scope; CI fails closed if the exact dependency cannot be fetched.
- Artifacts: OpenMLS build tooling/integration guide, separate `open-mls-ios` package metadata,
  checksums, README and CI, plus SDK Package.swift, README, CI verifier and this ledger changed.
  Bellboy runtime/API/SQL/Postman and PIN implementation remain unchanged.
