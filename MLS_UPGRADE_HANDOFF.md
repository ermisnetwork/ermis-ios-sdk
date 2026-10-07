# iOS SDK MLS upgrade runbook

Tài liệu này chỉ dành cho repository **`ios/ermis-ios-sdk`**: nhận UniFFI
artifact, package/link vào SDK, migrate local client persistence nếu cần,
build/test và canary iOS app. Không build Bellboy, không migrate server database
và không dùng Web WASM làm bằng chứng.

Contract server/canonical plan nằm trong
[bundle Bellboy](../../bellboy/docs/todo/e2ee_mls_group_rebootstrap_plan.md);
producer dùng [OpenMLS handoff](../../openmls/MLS_UPGRADE_HANDOFF.md).

## 0. Inputs và known preflight

Cần nhận:

- reviewed iOS SDK snapshot và dependency locks/resolution;
- Bellboy compatibility capability đã deploy, automatic rebootstrap còn tắt;
- atomic UniFFI set từ OpenMLS: generated Swift, header/module map, complete
  device+simulator XCFramework, release metadata và checksums;
- approved simulator/device, TEST account/channels và rollback owner.

Host app `ios/ermis-chat-ios` owns the runtime endpoint. `AppEnv.uhm` is
production and retains `https://api-trieve.ermis.network` for both base and
auth URLs. For `APP_TYPE=uhm`, `BASE_BUNDLE=live.sub2s.uhm` selects
`AppEnv.xoithit` (`https://api-dev.khoakheu.pro`); `network.ermis.uhm` selects
`.uhm`. Both identities behave the same in Debug and Release.
Rebuilding only `ermis-ios-sdk` does not change host mappings.
Sign in again after changing hosts because access and refresh tokens are
server-scoped. The preceding device artifact evidence predates this separation
and is superseded; the final signed-device canary remains unverified.

From `ios/ermis-chat-ios`, select the local flavor, then use the existing
`ErmisChat` scheme and Cmd+R:

```bash
# Personal TEST app, displayed as Uhm Dev.
sh Enviroments/setup_app_env.sh uhm-xoithit
# Production identity with its existing extension IDs and state.
sh Enviroments/setup_app_env.sh uhm
```

On another checkout, first copy `Enviroments/uhm-xoithit.env.example` to the
ignored `Enviroments/uhm-xoithit.env`. The template inherits the existing
ignored `uhm.env` OAuth configuration and contains no credentials.
Build flavors sequentially because they generate the same local config.
TEST uses separate Keychain and `group.live.sub2s.uhm.dev`; production retains
its existing group. Signing must allow that TEST App Group and
`live.sub2s.uhm.IntentsExtension`. The owner's screenshot confirms the main
app, NSE and ShareExtension IDs, not those remaining capabilities. Signed
Google login and authenticated MLS acceptance are unverified. A development-
signed local install and process launch are verified below.

Unsigned generic-device verification on 2026-10-02 passed for the final
identity-routed flavor:

```bash
xcodebuild -quiet -project ErmisChatiOS.xcodeproj -scheme ErmisChat \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/ermis-ios-uhm-xoithit-20261002 \
  -skipPackageUpdates -disableAutomaticPackageResolution \
  build CODE_SIGNING_ALLOWED=NO
```

The built app reports `Uhm Dev`, `live.sub2s.uhm`,
`group.live.sub2s.uhm.dev`, and the separate TEST Keychain identifier. Its
embedded targets are `live.sub2s.uhm.NSE`,
`live.sub2s.uhm.IntentsExtension`, and `live.sub2s.uhm.ShareExtension`; the
main executable contained the then-current `https://api.xoithit.lol`. The
current source now maps Uhm Dev to `https://api-dev.khoakheu.pro`, so that old
artifact is superseded for endpoint proof. Rebuild and inspect the host app
before using it for authenticated acceptance.

A subsequent signed generic-device build passed. Outside the filesystem
sandbox, `codesign --verify --deep --strict` passed; the main app and all three
extensions use team `P4F9DNFZ68`, Apple Development identity, valid embedded
profiles through 2027-10-02, and the TEST App Group. The provisioned iPhone 13
Pro Max accepted installation of `live.sub2s.uhm`, and `devicectl` launched the
process successfully. This verifies local signing/install/launch only; login,
actual network routing, push/share/intents, MLS repair and messaging remain
device acceptance work.

```bash
git branch --show-current
git rev-parse HEAD
git status --porcelain=v1
git diff --binary | shasum -a 256
git ls-files --others --exclude-standard
swift --version
xcodebuild -version
```

Current `Package.swift` links `Vendor/open-mls-ios` bằng local path và còn
cần sibling `../ermis-shared-ios`. Vì vậy source OpenMLS thay đổi không tự cập
nhật binary iOS. `scripts/verify-openmls-compatibility.sh` hiện còn kiểm remote
`0.1.0-m0.1`, không khớp local-vendor `Package.swift`; coi script đó là
**stale/no-go** cho release hiện tại cho tới khi được sửa và executable-test.
Không bypass bằng cách bỏ verify hoặc chỉ đổi version string.

**Known source snapshot 2026-09-15:** vendored `RELEASE_METADATA.json` ghi
OpenMLS `ea2310f46d716e29e28422c18b310dba06515267`, còn sibling OpenMLS HEAD
là `d5746f58e907ed3ddee01761656da7ce08de365c`. Dev phải chọn reviewed
artifact baseline rồi regenerate/package hoặc giữ artifact cũ với contract đã
chứng minh; không tuyên bố vendor hiện tại được build từ sibling HEAD. Reverify
snapshot này trước release.

## 1. Package artifact thực sự được link

So sánh OpenMLS handoff với:

- `Vendor/open-mls-ios/Sources/open-mls-ios/open_mls_ios.swift`;
- `Vendor/open-mls-ios/OpenMlsUniFFI.xcframework`;
- `Vendor/open-mls-ios/RELEASE_METADATA.json`;
- `Vendor/open-mls-ios/ARTIFACT_CHECKSUMS.sha256`.

Khi promote artifact mới, thay **toàn bộ set atomically**, không merge file mới
vào XCFramework cũ. Metadata phải chứa source commit/diff, `Cargo.lock`,
minimum iOS version, slices và required capabilities. Regenerate checksum từ
files đã package; không copy checksum cũ.

```bash
cd Vendor/open-mls-ios
shasum -a 256 -c ARTIFACT_CHECKSUMS.sha256
plutil -lint OpenMlsUniFFI.xcframework/Info.plist
find OpenMlsUniFFI.xcframework -type f -print0 \
  | sort -z \
  | xargs -0 shasum -a 256
cd ../..
```

Required linked API gồm explicit GroupId create/load, trusted
`processMessageAt`, typed `NoMatchingKeyPackage`, save/load provider và
archive v2. Generated Swift source-only không đủ nếu static library/header slice
không chứa cùng ABI.

## 2. Client persistence và call-path review

Review direct path:

`ErmisClient → E2eRepository → MlsClient → open-mls-ios/UniFFI → durable stores`.

Giữ các invariant:

- provider mapping keyed bằng CID + generation/GroupId; generation 0 đọc được
  persisted state cũ;
- candidate được checkpoint trước complete; ambiguous ACK reconcile receipt;
- durable inbox/cursor chỉ advance theo ordered processing; restart tiếp tục
  đúng generation;
- Welcome dành cho device được ưu tiên; typed external-join prerequisite tách
  khỏi generic sync/Welcome failure;
- old ciphertext/pending encrypted send không replay vào generation mới;
- trusted historical server acceptance time được giữ; missing/untrusted time
  fail closed; failed secret-consuming private commit không retry;
- history archive/gap tách khỏi chat readiness; revoked/pending/banned member
  không nhận thêm quyền.

Nếu Core Data model/schema thay đổi, dùng additive/lightweight migration hoặc
explicit tested migrator; không xóa store của người dùng làm “migration”.
Test upgrade từ persisted generation-0 fixture và process restart thật.

## 3. Build-for-testing và focused linked-artifact suites

Dùng simulator UDID có thật từ `xcrun simctl list devices available`:

```bash
xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme ErmisChat-Package \
  -destination 'platform=iOS Simulator,id=APPROVED_SIMULATOR_UDID' \
  -derivedDataPath 'PATH_TO_TASK_OWNED_DERIVED_DATA' \
  build-for-testing CODE_SIGNING_ALLOWED=NO

xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme ErmisChat-Package \
  -destination 'platform=iOS Simulator,id=APPROVED_SIMULATOR_UDID' \
  -derivedDataPath 'PATH_TO_TASK_OWNED_DERIVED_DATA' \
  -only-testing:ErmisChatTests/MlsGenerationRebootstrapTests \
  -only-testing:ErmisChatTests/MlsPersistenceTests \
  -only-testing:ErmisChatTests/MlsProviderStoreMigratorTests \
  -only-testing:ErmisChatTests/GroupInfoRepairCoordinatorTests \
  -only-testing:ErmisChatTests/E2eeMlsRolloutControlsTests \
  test-without-building CODE_SIGNING_ALLOWED=NO
```

Ghi destination, Xcode/Swift version, artifact hashes và exact pass/fail/skip.
`swift test`, mock test hoặc OpenMLS source test không thay proof qua linked
XCFramework. Với release hỗ trợ device, chạy thêm generic/physical iOS arm64
build-for-testing và approved device smoke; không để simulator/app state thừa.

### KeyPackage refill contract shared with Android

Both native clients treat `GET /v1/e2ee/key_packages/count?reason=...` as the
authoritative inventory. The server response supplies `remaining`, `target`,
`low_watermark`, `requested_delta` and a durable positive
`refill_generation`. A client generates exactly `requested_delta` packages only
when `remaining <= low_watermark`; contradictory, unbounded or generation-less
demand fails closed. Realtime `key_packages.low|empty|expiring` events are
wake-up hints and always lead back through the count endpoint.

iOS serializes OpenMLS mutation, allows one refill flight, applies a cooldown,
retries bounded upload failures, and verifies inventory again after upload.
The server owns target and watermark values; the removed client-side constant
must not be restored. Android follows the same validation and reconciliation
rules.

Local verification on 2026-10-03 used iPhone 18 Pro Simulator, iOS 27.0,
UDID `1CA7984A-F82B-4591-9384-77565950C855`. Build-for-testing passed, then
the six focused suites listed above plus `E2eeBase64TransportTests` passed
**79/0/0**. The retained first run was **78 passed / 1 failed / 0 skipped**
because the new event test expected a domain object directly from
`EventDecoder`; it was corrected to assert the DTO boundary used before
`EventsController` converts the event. After adding upload-response assertions,
the final current test bundle reran `E2eeMlsRolloutControlsTests` at **10/0/0**.

```bash
xcodebuild -quiet -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme ErmisChat-Package \
  -destination 'platform=iOS Simulator,id=1CA7984A-F82B-4591-9384-77565950C855' \
  -derivedDataPath /private/tmp/ermis-ios-kp-parity-20261003 \
  -skipPackageUpdates -disableAutomaticPackageResolution \
  build-for-testing CODE_SIGNING_ALLOWED=NO

xcodebuild -quiet -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme ErmisChat-Package \
  -destination 'platform=iOS Simulator,id=1CA7984A-F82B-4591-9384-77565950C855' \
  -derivedDataPath /private/tmp/ermis-ios-kp-parity-20261003 \
  -skipPackageUpdates -disableAutomaticPackageResolution \
  -enableCodeCoverage NO \
  -only-testing:ErmisChatTests/E2eeMlsRolloutControlsTests \
  -only-testing:ErmisChatTests/GroupInfoRepairCoordinatorTests \
  -only-testing:ErmisChatTests/MlsGenerationRebootstrapTests \
  -only-testing:ErmisChatTests/MlsPersistenceTests \
  -only-testing:ErmisChatTests/MlsProviderStoreMigratorTests \
  -only-testing:ErmisChatTests/E2eeBase64TransportTests \
  test-without-building CODE_SIGNING_ALLOWED=NO
```

## 4. TEST canary và version skew

Sau khi Bellboy capability đã deploy:

1. generation 0 existing channel vẫn load/decrypt/send;
2. valid GI + missing local group đi normal external join, không reset;
3. missing/stale/invalid GI đi repair; 15 phút là
   server-side `first_unresolved_at`, app restart không reset timer;
4. Welcome đúng device, no-matching-KeyPackage fallback và device offline/
   return-after-retention;
5. claim/complete/receipt, ambiguous ACK, restart trước/sau checkpoints;
6. membership removal/role change, repair-wins-race và stale lease;
7. same CID/different generation, same epoch/different generation;
8. history restore/gap, missing wrap/archive, revoked membership và
   `self_owned_only`;
9. new iOS + old server fail closed typed; old iOS + new server dùng generation
   0; old iOS trên activated generation nhận upgrade-required behavior.

UI/readiness phân biệt waiting repair, preparing, recovered, history incomplete,
retryable infrastructure và upgrade required. Render/send retry không tạo
sync/repair/rebootstrap loop. Chỉ ready khi current-generation group usable.

## 5. Cost, rollback và evidence

Local provider lookup theo generation/GroupId là `O(1)` theo key; restore/sync
là `O(E)` theo events và tree/provider memory `O(M)` theo members. Welcome
install/fan-out payload `O(K)`; historical archive cost theo ciphertext/wraps.
Đo startup/restart latency, provider/tree/Welcome bytes, peak RSS/copies,
durable-store writes và 100-member/200-device cases trên linked artifact.

Rollback trước activated generation bằng SDK/app release cũ nếu Bellboy/client
compatibility matrix cho phép. Sau activation, không rollback về iOS artifact
không hiểu generation; sửa forward. Không xóa Core Data/provider/archive/cursor
để tạo pass và không resend old-generation payload.

| Evidence | Nội dung |
|---|---|
| Source | Commit/diff, dependency state, Xcode/Swift |
| Artifact | Metadata, checksums, both XCFramework slices, linked API/ABI |
| Persistence | Generation-0 migration, restart, cursor/candidate checkpoints |
| Tests | Exact build/test commands và pass/fail/skip |
| Runtime | TEST device/app build, typed flows, no old replay |
| Rollback | Compatible build ID, trigger và durable-state preservation |

<details>
<summary>Change log</summary>

- `2026-09-15`: Added repository-owned iOS MLS upgrade instructions.
  - Reason: linked UniFFI adoption and local persistence cannot be proved in the Bellboy runbook.
  - Integrator action: iOS owner packages the complete vendor artifact and runs linked simulator/device tests.
  - Compatibility/default: documentation only; the stale compatibility script remains an explicit release blocker.

</details>

## 2026-10-03 shared repair ACK correction

`UserDefaultsGroupInfoRepairStore.remove` now selects epoch-bearing ACKs only by minimum-epoch coverage; the same request ID cannot erase newer work. Request-only cancellation and account/device/CID scope stay compatible. Actual UserDefaults close/reopen/scope regression is added to `GroupInfoRepairCoordinatorTests`. Rebuilt linked SDK suite **9/0/0** on arm64 iPhone18Pro/iOS27 simulator passes. [Exact build/test/artifact evidence](../../bellboy/docs/evidence/local_main_plan/20261003-android-coordinator/README.md), [shared canonical journal](../../bellboy/docs/todo/e2ee_mls_group_rebootstrap_plan.md#2026-10-03--shared-ack-fence-verified). Native XCFramework/Swift binding is unchanged. Physical iPhone13ProMax connection detected only; no installed/authenticated new-device MLS acceptance claimed. Existing79-test report remains tied to its preceding source. No app flavor, server config, schema or rollout flag changed.


## 2026-10-05 — Fresh invitation fallback and join readiness follow-up

[Canonical plan](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md),
[failed MLS-Join-02 window](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/fresh-group-initial-join-owner-failed.json),
[final native/app provenance](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/mobile-join-wakeup-provenance.json).

iOS actual Welcome is targeted but NoMatchingKeyPackage; durable prerequisite
previously lacked bootstrap wake-up. Accepted invite and durable typed failure
now admit existing coordinator; realtime typed failure goes through durable sync.
No timer/generic-error fallback or bypass of rollout/GI/membership/cursor fences.
Private-KP mismatch origin remains open; external join cannot fabricate prehistory.

Android Welcome install/replay and accepted external join now republish status
using native operational/rebootstrap and pending-GI gates, retaining history
incomplete behavior. Named group Room metadata: one decoded message, generation0
marker, no pending repair/rebootstrap; old RETRYABLE banner blocked sending.
Actual native coordinator15/0 on API35 emulator, iOS focused12/0 on simulator,
parser14/0 and host builds pass. Both Uhm apps installed preserving data; physical
Android hash matches final APK; Uhm Dev signed and contains new wake-up marker.
Owner same-group send/banner acceptance and fresh-group without restart gate
remain UNVERIFIED. No broad checkbox closure, server change, commit or deploy.


## 2026-10-05 — Storage diagnostics and private-KeyPackage audit

Canonical [Android/cross-client parity journal](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-05--scoped-history-audit-and-selected-ios-package-mismatch-verified) retains current narrow acceptance and prior failures. [New signed Uhm Dev diagnostics provenance](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/storage-selection-provenance.json) binds factory/container fixed storage markers only; selection/migration/fallback behavior unchanged. Actual startup account_disk selected -> disk loaded, parser16/0 and focused disk-prerequisite/provider-reset2/0/0. File-service listing still omits chat SQLite; no claim of memory fallback. New artifact owner cache/offline acceptance pending.

[Selected earlier iOS KP comparison](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/ios-selected-kp-local-identity-comparison.json): all50 current private bundles have a different signing identity from the earlier server-selected iOS package.0 init matches/0 signature matches. This explains that typed Welcome mismatch; exact identity-change origin/current server pool completeness remain unverified. No store or pool purge, device-ID rotation, token replay or API/schema change. Existing typed fallback's actual no-restart fresh join PASS retained on parent artifact; do not equate it with inventory reconciliation or recovery of pre-join history.

Follow-up: native generated-KeyPackage disk reset/reopen/Welcome/decrypt [regression](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/storage-selection-kp-regression.json)1/0/0 PASS; test-only source added to provenance, app binary unchanged. Final diagnostics artifact offline cache-before-network and catch-up acceptance is armed on the same MLS-Join-04, still owner-pending. [Canonical continuation](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-05--native-generated-keypackage-reopen-regression-passed-final-ios-offline-probe-armed) records replacement Android/Web collectors, retained gap and distinct phases. Old server-package identity mismatch and2 historical Android cache misses remain OPEN.


## 2026-10-05 — Returning Uhm offline startup admission repaired; physical retest pending

Original offline startup reports ConnectionNotSuccessful before chat UI; [failure retained](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/ios-offline-storage-phase2-failed.json). New read-only `canReadCachedSession(afterConnectionFailure:token:)` uses existing unavailable network monitor + non-expired token, matching account/project/user-scoped real SQLite cache/current-user row; generic/auth/server failures and missing cache remain rejected. Returning Uhm AppCoordinator renders cached chat on that result; first login/Ermis-chain startup, connection/auth and MLS/send gates unchanged. SDK README + client-guide session contract updated; no wire/schema migration.

[Installed final provenance](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/cached-session-provenance.json): actual simulator disk eligibility8/0/0, parser18/0, signed uhm-xoithit build/install PASS. iOS first post-install offline launch refused OS verification; owner enabled network and opened app. Agent now has online captured startup, not offline acceptance. Retest same MLS-Join-04 cached3 before networking, then a fresh offline batch; original queued OFF-I messages may already be fetched during verification warm-up. [Canonical continuation](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-05--cached-session-fix-installed-os-offline-launch-verification-retained-retest-armed). Broad/history/KP-origin gates OPEN.


## 2026-10-05 — Production offline wrapper correction installed; owner retest pending

First repair failed actual offline admission; [retained owner failure](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/cached-session-offline-retest-failed.json) and [production wrapper regression0/1/0](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/cached-session-wrapped-repro-failed.json). Corrected `ConnectionNotSuccessful.isOffline` unwraps the known socket/engine transport chain only. Eligibility rejects `/dev/null` logical memory, retains monitor/account/project/token/cache guards and emits fixed reasons; connect/auth/send/cursor/ratchet semantics unchanged.

[Latest provenance](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/cached-session-classification-provenance.json): simulator policy12/0/0, parser20/0, signed Uhm Dev build/signature/preserving-data install/captured launch PASS. Latest startup did not exercise failed-connection branch, so cached-read and fresh offline catch-up UNVERIFIED. Owner confirmation of airplane-mode ON/Wi-Fi OFF/app closed requested before captured relaunch. [Canonical journal](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-05--offline-transport-classification-installed-physical-offline-branch-pending). Broad/history/KP-origin gates OPEN.


## 2026-10-05 — Corrected artifact physical offline cache accepted; catch-up owner success with console gap

[Fresh round2 offline evidence](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/cached-session-fresh-offline-round2-phase2-runtime.json): owner old FIRST3/OFF2 cache visible/readable while fresh CACHE2 trio absent; final artifact disk loaded, offline cause classified and cached session admitted. Bounded ordinary offline close/reopen/cached-read PASS. [Network-restoration result](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/cached-session-fresh-offline-round2-phase3-result.json): owner immediate3 receipt/iOS reply/capture0, Web/Android reply persistence chains captured. iOS console exits1 before receive, so internal iOS3 receive persistence remains UNVERIFIED. No broad crash/cursor/ratchet/history/KP-origin closure. Preserve failure/gap; prepare capture continuity or durable evidence before another owner test. [Canonical journal](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-05--fresh-round2-catch-upreply-owner-success-ios-console-gap-limits-closure).


## 2026-10-05 — Debug retained marker file capture installed; final-artifact owner round pending

`MlsFieldLogDestination` projects the shared `MlsFieldMarkerContract.json` before disk, bounds current/previous files256KiB each, excludes backup and records recovered write failure. Debug live.sub2s.uhm host opts in before client creation; console and crypto/provider/cursor semantics unchanged. Exporter lists/copies/validates fixed files without restart and rejects copy-time size/mtime change, partial/unknown/oversize content, clock reversal/future rows. Best-effort async diagnostics with possible Logger caller backpressure; no atomic/crash proof, no NSE coverage.

[Final provenance](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/ios-persisted-capture-provenance.json): native24/0/0, exporter14/0, existing console parser20/0, signed build/install/launch and actual stable startup18-row file export PASS,37 source paths. Same MLS-Join-04 fresh PERSIST-W1/W2/A1 offline then restored-network PERSIST-I1 reply scenario armed, owner pending. Read persisted native snapshot even if console exits; inspect scenario coverage/no-write-failure and expected stage chains. Parent owner passes remain bound to parent artifacts. [Canonical journal](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-05--fixed-marker-capture-installed-and-physically-exportable-owner-round3-armed); broad cursor/ratchet/history/KP-origin/environment gates OPEN.


## 2026-10-05 — Final diagnostic artifact ordinary offline/restart exchange accepted

[Canonical runtime journal](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-05--final-persisted-round3-ordinary-restart-and-iphone-first-exchange-accepted) and [final result](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/ios-persisted-round3-phase4-exchange-result.json) supersede the owner-pending status for this final diagnostic artifact only. Explicit offline relaunch loads disk/cache, old plaintext remains readable after close/reopen; fresh catch-up has retained3 decoded/provider/cursor sequences; later iPhone-first exchange has retained2 realtime decoded/provider pairs and both peers' receive chains. Owner all3/capture0. Retained snapshots stable, scenario start covered and0 write failures; console/file counts not merged. Realtime path does not emit scope cursor, so its absence is not a decrypt failure or evidence of full cursor proof.

Ordinary user-visible cached read/catch-up/send/receive continuation PASS. Earlier console gaps/online-precondition mismatch/failed classifier reports retained; no reconstruction of parent missing windows. Exact crash/provider-cache transaction/full-prefix/ratchet concurrency, old Android2 history and stale iOS selected-KP ownership remain OPEN. No need to repeat ordinary owner exchange; next automated scope is Android actual coordinator invite-sync abrupt-kill matrix in an isolated synthetic package, with physical acceptance separately required. No production/server or crypto/storage behavior change in this handoff.

### 2026-10-06 — iOS retained-channel acceptance after kick/leave

Accepted-invite processing restores this project's current user's membership even when removal cleared it, and re-inserts the accepted member into channel/member-list relations. Project authentication is read before saveMember/saveUser can attach a project user to CurrentUserDTO. Unrelated acceptance must not restore local membership. Existing database, device identity, MLS provider, ratchet and cursor semantics are preserved; no server contract changes.

Five Core Data regression cases (including ten repeated removal/acceptance cycles) and three existing native typed-Welcome/fallback/bootstrap cases pass locally. Actual RJ01 remains FAIL: iOS needed restarts and only read its own retry while peers read new messages. Local tests/build do not close this physical gate; repeat the same-channel native-first scenario with logs before accepting the fix. See [canonical journal and open gates](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-06--accepted-member-core-data-correction-verified-locally-physical-gate-remains-failopen).


### 2026-10-06 — Live reinvite membership reconciliation (CLIENT-005-MEMBER-REJOIN)

RJ03 iOS group remains absent after Android accept; restart rescues send. Gate FAIL/OPEN. Realtime targeted Welcome for a missing group and current-account accept now trigger E2eeMembershipRefreshCoordinator: coalesced existing channel query, exact scope/account/device and joined membership checks, Core Data membership plus members relation, internal ChannelMembershipRefreshedEvent, then existing durable bootstrap. Invalidate outstanding refresh on removal. No new backend contract/schema, provider/cursor purge or generic MLS-error fallback. Zero-member query still needs own member relation because allChannels predicate uses members.user.id. Bounded marker: mls_membership_refresh result=started|coalesced|joined|not_joined|failed|superseded.

Canonical narrative/evidence and remaining gates: [Android parity plan](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-06--ios-authoritative-membership-refresh-designed-before-correction); ledger [CLIENT-005-MEMBER-REJOIN](../../bellboy/docs/todo/e2ee_mls_keypackage_lifecycle_plan.md). Local tests/build/install do not close the device gate; retest same group/data, native sends first, stop on failure without restart.


### 2026-10-06 — Returning-session token persistence and bounded diagnosis

RJ04 still fails live reinvite; later owner screenshot is a separate launch/auth blockage. Native file shows disk loaded but cached read blocked connection_type. Host/ShareExtension refresh callbacks incorrectly reparse old Keychain JWT. Correct them to persist `AuthenticationPayload.validatedToken(matching:)`, retain refresh credential when rotation omitted, and fence stale account/project callbacks. SDK provider validates the same response before helper update/callback; missing refresh credential is typed and does not purge stores. Host uses concrete ClientError description/expired-session localization rather than generic NSError1. Fixed auth stage/category/code and membership role/banned/blocked markers diagnose physical retry without secret logging.

Canonical [parity implementation journal](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-06--foreground-startup-blocked-by-generic-auth-error-token-persistence-correction-designed); ledger [CLIENT-005-MEMBER-REJOIN](../../bellboy/docs/todo/e2ee_mls_keypackage_lifecycle_plan.md). Exact alert cause still unverified until final-artifact device retry. No new membership cycle or environment gate passed.

### 2026-10-06 — Native refresh-token follow-up

Owner requested iOS/Android refresh parity after iPhone startup log confirmed missing refresh credential. Reuse [canonical native refresh design/journal](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#client-auth-refresh--iosandroid-credential-renewal) and [AUTH-001…004 ledger](../../bellboy/docs/todo/e2ee_mls_keypackage_lifecycle_plan.md#client-auth-refresh). No token/provider/cursor purge or broad membership gate closure. Persist initial server credentials, validate/retain rotation, coalesce active renewal, bind Android real Uhm reconnect consumers and retry HTTP with a fresh header. Exact commands/source/artifact/device results follow in the canonical journal; simulator/JVM passes do not establish physical expiry acceptance. Host/ShareExtension cross-process Keychain transactions and secure Android storage migration are not claimed.

Local refresh result: iOS47/0/0 and Android19/0/0; final signed apps installed, drift0, actual Android startup refresh/persistence observed. [Combined evidence](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/membership-rejoin/mobile-refresh-local-device-progress.json) binds exact commands/artifacts and retained failures. Owner same-group readiness and full expiry/restart messaging remain unverified; no full gate closed.


### 2026-10-06 — Own-member event reconciliation parity

Own member.added/updated/joined now wake authoritative refresh; member middleware restores nil own membership/roster by project-authenticated user and preserves missing-channel member conversion. Session-bound invite hints bridge the first pending metadata query; own changes supersede older in-flight response and coalesce one fresh query. Removal/changed session cannot publish or wake bootstrap. 36 focused simulator cases PASS; signed final Uhm Dev installed preserving data. No provider/cursor/ratchet changes. Physical no-restart repeated acceptance still FAIL/OPEN.

Canonical [design/journal/provenance](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-06--android-own-member-parity-review-and-guarded-refresh-design) and [authoritative CLIENT-005-MEMBER-REJOIN ledger](../../bellboy/docs/todo/e2ee_mls_keypackage_lifecycle_plan.md). Local tests/build/install do not close owner runtime gates.


### 2026-10-06 — Missing-cache MLS acceptance converter correction (field gate OPEN)

RJ08 iPhone self-leave→Android accept fails automatic iPhone group visibility; foreground later rescues group via typed external join, prior Android ciphertext remains encrypted. Missing-channel actual middleware regression fails before correction (0/1/0). NotificationInviteAcceptedEventDTO now preserves existing public full event or emits internal MLS-only E2eeInviteAcceptedSignalEvent to authoritative membership refresh when model unavailable; no fabricated metadata/READY or storage fences bypassed. Current-account/session/exact-CID joined query must persist own membership/roster and publish list before bootstrap. Android decoder/coordinator already cache-independent; its unbound crypto/barrier diagnostics remain unresolved.

Focused middleware/coordinator/marker tests41PASS/0FAIL/0SKIP, signed Uhm Dev setup/build0; install/owner retest tracked in [artifact provenance](../../bellboy/docs/evidence/local_main_plan/20261004-three-platform-field/membership-rejoin/r08-accepted-signal-provenance.json). [Canonical journal](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-06--rj08-return-fail-missing-channel-acceptance-conversion-investigation), [ledger CLIENT-005-MEMBER-REJOIN](../../bellboy/docs/todo/e2ee_mls_keypackage_lifecycle_plan.md). Build/unit tests do not close gate; repeat same group with iPhone initiating leave, Android accepting, iPhone sending first before peer application traffic.


## 2026-10-07 KP ownership, crash boundaries and refresh continuation

Canonical implementation/history/status: [existing parity plan](../../bellboy/docs/todo/e2ee_mls_android_parity_plan.md#2026-10-07--authorized-kp-ownership-durability-and-authentication-follow-up); authoritative [lifecycle ledger](../../bellboy/docs/todo/e2ee_mls_keypackage_lifecycle_plan.md). Android loads SQLite identity before one-time legacy preferences migration; Web never replaces unreadable provider state; iOS batch generation throws instead of empty uploads. No server pool purge or ownership reconciliation endpoint added. Existing typed authorized fallback retained.

Evidence: [source/artifact provenance](../../bellboy/docs/evidence/local_main_plan/20261007-kp-durability-auth/artifact-provenance.json). Web65focused PASS; Android23JVM/26native/6Room+HTTP multi-channel crash boundaries PASS; iOS50focused/4receiver SIGKILL boundaries PASS. Failed compile/preparation/overlap reports retained in the canonical journal. Native libraries unchanged.

iOS connected `refreshAuthentication` uses the existing provider; explicit DEBUG field renewal was accepted and persisted on the physical iPhone. This is forced HTTP renewal, not natural expiry acceptance. Updated Uhm/Uhm Dev preserve real data; owner retained/new-message confirmation pending. Old server KP mismatch, complete call-path atomicity and historical crypto failures remain OPEN. Owner waived further routine membership repetitions.
