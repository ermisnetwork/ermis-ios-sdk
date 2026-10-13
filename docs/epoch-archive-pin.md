# Epoch archive–PIN trên iOS và Android

## Hành vi đã triển khai

- PIN thuộc về user và được cấu hình/mở khóa từ màn hồ sơ, không nằm trong menu từng channel. Lần login thật giải thích PIN dùng để mở kho archive và đưa toàn bộ channel E2EE vào queue restore; bỏ qua thì có thể tiếp tục từ mục PIN khôi phục lịch sử trong hồ sơ. Repair từng channel hoặc lỗi đồng bộ không thể tự khắc phục chỉ hỏi PIN khi vault chưa mở khóa.
- Logout xóa khóa mở vault và chặn ghi từ callback của session cũ. Journal và checkpoint đã mã hóa giữ lại cho đúng account/project/device khi đăng nhập lại.
- Repair channel chạy sync/repair MLS trước rồi khôi phục application history. Khi sync xác nhận thiếu lịch sử hoặc application không thể giải mã sau replay, SDK lưu yêu cầu restore. Chỉ yêu cầu PIN nếu khóa mở vault thiếu hoặc không khớp vault hiện tại. HTTP/network/storage lỗi chuyển sang retry, không tự tạo yêu cầu PIN.
- Mỗi sự cố mới tạo một chu kỳ restore mới để đọc được message mới trong epoch đã restore trước đó. Retry cùng chu kỳ tiếp tục từ cursor đã lưu; các yêu cầu đang chờ được gộp khoảng epoch.
- Archive recovery không thay Group, Commit, Welcome, generation hoặc live sync cursor. Chỉ xuất bản message đã xác thực; DB bảo vệ message đã sửa/xóa và ghi ciphertext/plaintext cùng transaction.
- PIN trong UI có 8–12 chữ số. Core dùng PBKDF2-SHA256 600.000 iterations, HPKE suite 3 và AES-GCM theo định dạng/domain của web. Không lưu PIN.

## Queue upload bền vững

Capture epoch **trước lần encrypt/decrypt application đầu tiên** và trước khi retire epoch cũ. Hai checkpoint `account_owned` và `group_sponsored` được bảo vệ bằng khóa thiết bị. Capture chỉ thực hiện một lần cho cid/generation/epoch.

Worker lưu sealed body, blob ID và idempotency key vào SQLite journal **trước HTTP**. Retry/restart dùng lại ciphertext, nonce, AAD và wraps đã lưu. ACK `stored`, `idempotent`, `duplicate_cap` được commit cùng việc xóa pending upload; lỗi transaction giữ nguyên pending. Sau ACK mới xóa checkpoint chứa archive.

| Kết quả | Hành vi |
| --- | --- |
| Offline, timeout, HTTP 5xx/408/429/401 | Retry có exponential backoff/jitter, tối đa 5 phút; giữ payload |
| Server error code 6 | Pause `permission_denied`; chỉ retry riêng cid qua repair hoặc `retryBlockedArchiveUploads` |
| `recipient_set_stale` | Đọc lại recipients và tạo blob/wrap mới, tối đa 2 lần; sau đó giữ terminal |
| Sponsored policy/recipient limit/unsupported endpoint | Giữ trạng thái unsupported; account-owned tiếp tục độc lập |
| Matching sponsored candidate | Ghi coverage ACK, bỏ checkpoint đã được bao phủ |
| Backup sponsor | Chờ 5 giây; chỉ device được chọn theo user ID/leaf index trong snapshot thực hiện |

Journal có index theo kind/status/due time/cid; mỗi page tối đa 50 hàng và budget payload 8 MiB, vẫn cho đọc một hàng lớn riêng lẻ. Mỗi payload tối đa 16 MiB. Restore đọc availability/ciphertexts tối đa 100 hàng/page, material từng epoch. Worker chạy trong SDK account owner; trên mobile, tiến trình bị suspend/kill sẽ tiếp tục khi app được chạy lại. Đây không phải cam kết upload liên tục khi app bị hệ điều hành đóng.

## Flag và UI

<details>
<summary>Change log</summary>

- `2026-10-11`: Queue restore theo request login và ACK sau journal commit; xem mục Login restore và test bypass để tích hợp API durable.

</details>

SDK mặc định `epochArchiveEnabled = false`. Sample đã bật:

- iOS: `ErmisChatiOS/ErmisChatWrapper.swift`, `scopedConfig.e2eeMlsRolloutControls.epochArchiveEnabled = true`.
- Android: `ChatInitializer.kt` và `CustomLoginViewModel.kt`, `MlsRolloutControls(rebootstrapEnabled = true, epochArchiveEnabled = true)`.

Cả hai sample đặt **PIN khôi phục lịch sử** trong màn hồ sơ. Mở khóa cho request login sẽ truy vấn các channel đã tham gia, lọc channel E2EE và enqueue restore cho từng channel; SDK journal giữ queue qua restart. Menu channel chỉ còn **Repair encrypted channel**. Android vẫn hỗ trợ nhấn giữ header và recovery banner để repair. PIN prompt do sample app quản lý, SDK cung cấp trạng thái và API setup/unlock/restore/retry.

## Bật log và chạy test máy thật

iOS Debug sample dùng `LogConfig.level = .debug`, subsystem `.mls`, `ConsoleLogDestination` và `MlsFieldLogDestination`. File log trên thiết bị: `Documents/mls-field-capture/current.log`, `previous.log`. Contract chỉ cho marker cố định lên đĩa. Android Debug sample dùng `ChatLogLevel.ALL`. Các marker archive chỉ chứa stage/reason/count/epoch/generation/scope, không chứa PIN, private key, plaintext hoặc ciphertext.

Lệnh dưới đây chạy từ workspace `chat`; thay device ID và đường dẫn output theo máy đang kết nối.

```sh
cd android/ErmisSdk-Android
./gradlew :ermis-chat-client:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=network.ermis.client.e2ee.MlsArchiveRecoveryInstrumentedTest \
  :ermis-ui-components-sample:assembleUhmDebug
python3 scripts/verify-openmls-artifact.py
```

```sh
cd ios/ermis-ios-sdk
bash scripts/verify-openmls-compatibility.sh
xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme ErmisChat-Package -destination 'id=<iphone-id>' \
  -derivedDataPath /private/tmp/epoch-archive-sdk-tests \
  -only-testing:ErmisChatTests/E2eeArchiveRecoveryTests build-for-testing
python3 scripts/run-archive-device-tests.py \
  --device '<iphone-id>' \
  --sample-app '/private/tmp/epoch-archive-pin-ios/Build/Products/Debug-iphoneos/Uhm.app' \
  --products '/private/tmp/epoch-archive-sdk-tests/Build/Products' \
  --result '/private/tmp/epoch-archive-device.xcresult'
```

Build và ký sample iOS trước khi chạy helper. Helper tạm cài XCTest host cùng bundle ID, giữ app data, rồi cài lại signed sample trong `finally`.

```sh
adb -s '<android-id>' logcat -d -t 5000 | \
  rg -o 'archive_(upload|recovery) stage=[A-Za-z_]+( [A-Za-z_]+=[A-Za-z_0-9]+)*'
xcrun devicectl device copy from --device '<iphone-id>' \
  --domain-type appDataContainer --domain-identifier network.ermis.uhm \
  --source Documents/mls-field-capture --destination /private/tmp/mls-field-capture
```

Native/web interoperability dùng **dummy fixture**, không đưa vault/key thật vào script:

```sh
cd openmls
cargo run -q -p openmls-recovery --example interop > /private/tmp/epoch-native-fixture.json
node openmls-recovery/scripts/interop.mjs \
  ../ermis-chat-monorepo/packages/ermis-chat-sdk/src/encryption/wasm \
  /private/tmp/epoch-native-fixture.json /private/tmp/epoch-web-fixture.json
cargo run -q -p openmls-recovery --example interop -- verify < /private/tmp/epoch-web-fixture.json
```

## Bằng chứng ngày 09/10/2026

- Rust: 7 test pass; tamper/wrong PIN/wrong recipient/generation, journal reopen/ACK rollback, due paging và payload budget. Log `/private/tmp/epoch-archive-rust-tests-final.log`.
- WASM source `cargo check` pass; crypto native → WASM web và WASM web → native pass. Interop dùng artifact web hiện có trong checkout.
- PHB110 Android 16 (`f9e14d35`): 6 instrumentation test pass; native crypto, Keystore restart, journal transaction, HTTP 503/restart/identical payload, code 6 pause, restore cần PIN rồi restore sự cố mới không nhập PIN, Room chống ghi đè/resurrect. Upload test dùng generation lớn hơn 2^53 và kiểm tra ciphersuite JSON là số nguyên. Log `/private/tmp/epoch-archive-android-final4.log`.
- iPhone 13 Pro Max (`00008110-000578EC11F2401E`): 7 XCTest pass; native crypto, Keychain, journal transaction, logout fence, wire integer/fractional metadata, wrapped HTTP 503/code 6, hai lần restore cùng epoch không thay live state. Log `/private/tmp/epoch-archive-ios-hosted-tests7.log`, result `/private/tmp/epoch-archive-ios-hosted-tests7.xcresult`.
- Sample iOS/Android build, được cài và launch trên hai máy thật. iOS field log sau launch có `archive_recovery stage=ready`; bản sao `/private/tmp/epoch-archive-ios-field-capture-final`.

## Retest trên Uhm thật ngày 11/10/2026

- Bellboy archive service tests: 10/10 pass (`cargo test service::mls_archive::tests --lib`).
- OnePlus 11 PHB110 / Android 16: cài và mở `network.ermis.uhm` `1.4.4-DEBUG`; archive instrumentation 6/6 pass. Log runtime cho thấy archive account-owned ở epoch 23, 24, 29, 30 được backend ACK `uploaded`; marker đã lọc tại `/private/tmp/archive-pin-android-live.log`.
- iPhone 13 Pro Max: build/ký/cài và mở `network.ermis.uhm` Debug, APNs development khớp. Runtime trước sửa cho thấy `captured → queued → acknowledged` trên backend thật. Không có PIN vì login callback chỉ phát notification ở `isFirstLogin`; phiên Keychain tự khôi phục dùng `isFirstLogin=false`.
- Đã sửa sample iOS phát yêu cầu kiểm tra vault sau mọi lần xác lập phiên đã xác thực. Presenter hỏi khi vault còn khóa, yên lặng khi đã mở khóa, và lưu lựa chọn bỏ qua cho tới khi có incident/Repair. Bản sửa đã build/cài lên iPhone; kết quả prompt locked-vault và PIN ở lượt tiếp theo được ghi bên dưới.
- Repair cùng channel trên hai máy ghi `archive_recovery stage=restoring` rồi `stage=done restored=13` trên cả Android và iOS; người dùng xác nhận 13 tin cũ giải mã đúng trên cả hai app. Upload/restore chỉ chứng minh phần lịch sử có archive coverage; không thể khôi phục epoch/message chưa từng được upload.

Instrumentation/XCTest dùng account/HTTP fixture; ngày 11/10 đã xác nhận upload và restore qua backend thật. iOS PIN status báo vault đã mở khóa, phù hợp với khóa recovery còn trong Keychain nên không yêu cầu nhập lại; login notification mới đã build/cài, ở lượt đó vault vẫn unlocked; lượt bypass locked-vault tiếp theo đã pass như ghi bên dưới. Log field cũ từng ghi `external_join_group_info_failed`/`readiness=failed`; lần test hiện tại đã ghi `readiness=ready`. Archive không sửa live MLS bằng lịch sử application.

Checklist backend thật trên channel test có MLS state hợp lệ:

1. Login → nhập/tạo PIN một lần; kill/reopen, refresh token, reconnect → không nhắc lại. Logout/login → nhắc đúng một lần; skip → chỉ nhắc khi repair/mất lịch sử.
2. Gửi/nhận ở epoch mới; ngắt mạng trước upload, kill app, mở lại online → queue dùng cùng blob/ciphertext, ACK chỉ một lần.
3. Repair hoặc tạo gap application không replay được → dùng khóa đã lưu; xóa unlock bằng API để kiểm tra prompt và resume từ checkpoint sau unlock.
4. Sponsored recipients thay đổi → rewrap có giới hạn; code 6 → không retry tự động, repair chỉ mở lại queue đúng channel.
5. So sánh plaintext đã restore, message sửa/xóa, attachment/forward AAD và generation; xác nhận live protocol cursor không đổi bởi archive recovery.

Native artifacts được build từ checkout OpenMLS đang dirty và ghi lại source manifest/checksum; đây là artifact development, chưa phải release đã ký/phát hành. Các thay đổi OpenMLS/web có sẵn trước công việc này được giữ nguyên.

## Login restore và test bypass

<details>
<summary>Change log</summary>

- `2026-10-11`: Login restore chỉ ACK sau khi ghi bền vững mọi job vào SDK journal.
  - Reason: enqueue bất đồng bộ trước đây có thể đánh dấu xong dù journal chưa ghi được.
  - Integrator action: dùng `enqueueRestoreDurably`, giữ pending khi API throw và retry khi vault còn unlocked.
  - Compatibility/default: `enqueueRestore` cũ vẫn dùng được; flag archive mặc định vẫn tắt. Marker ACK v2 theo request UUID cho từng login, không tái sử dụng marker v1 suốt vòng đời tài khoản.

</details>

Sample tạo request UUID mới khi login thật. Sau PIN đúng, app đọc channel theo page 100, enqueue bền vững từng channel E2EE, kiểm tra lại account/project/request rồi mới ACK request. Thất bại giữ pending và retry cách ít nhất 5 giây; request đang chờ giữ restore cycle/cursor đã ghi. ACK là xác nhận queue đã ghi, không phải xác nhận mọi lịch sử đã giải mã xong.

Trong Debug, mục **Khác/More → Quyền riêng tư và an toàn → Mã hóa đầu cuối → Lưu trữ tin nhắn → Kiểm thử login → PIN** dùng token provider/refresh token của phiên hiện có để refresh xác thực, xóa unlock cục bộ và tạo request login mới. Không logout, không đổi PIN, không xóa journal hay message cache. Nếu refresh thất bại hoặc chưa có vault thì dừng mô phỏng. Release không có lối vào này.

Android cũng nhận Intent extra `archive_pin_login_bypass=true` trên `HostActivity`; iOS nhận launch argument `--archive-pin-login-bypass`. Không truyền token/PIN qua launch argument. Người test nhập PIN trong prompt thông thường; automation đọc PIN từ file riêng ngoài repository.

Marker cố định: `archive_login stage=authenticated|prompt|unlock|queued result=accepted|failed|shown`, queue thành công thêm `channels=N`. Android Debug ghi marker trực tiếp bằng tag `ArchiveLogin`/`MlsArchive`; nên thu log liên tục vì Debug toàn mức có thể làm logcat xoay nhanh.

## Tiến độ 11/10/2026 — production integration, bản Debug trên máy thật

- Sửa iOS/Android SDK durable enqueue và giữ cycle khi retry; Android bắt thêm lỗi journal trong bước lên lịch retry để không crash worker/process.
- Sửa presenter hai sample: ACK theo request, retry queue; iOS giữ error alert qua chuyển tiếp UIKit khi PIN sai; Android lưu incident đã bỏ qua theo account/project/request để không mất lựa chọn khi restart. Android SDK thêm `refreshAuthentication()` dùng TokenManager/provider hiện có.
- iPhone 13 Pro Max: 8/8 SDK XCTest pass (bao gồm lỗi SQLite journal, reopen, stopped-owner rejection); UI pass PIN sai → thử lại → PIN đúng → reopen, và bỏ qua → reopen → cài đặt → PIN đúng. Hai lượt qua backend thật đều queue 15 channel; mỗi lượt tổng `restored` ở các terminal marker là 604. Đây là số thao tác restore báo cáo, không phải 604 tin mới khác nhau giữa các lượt.
- PHB110 Android 16: SDK instrumentation 7/7 pass, gồm fault injection vào đường ghi restore thật, reopen journal và stopped-owner rejection. UI đã pass PIN sai/đúng → ACK request mới → backend restore → reopen, và bỏ qua → reopen không bật prompt cũ → cài đặt → PIN → ACK/restore. Driver kiểm tra ACK bền vững từ preferences của app vì marker queue có thể vắng ở nhánh request đã ACK; không suy ra queue hoàn tất chỉ từ việc đóng prompt.
- Cả hai app Debug đã build/ký/cài trên thiết bị. Artifact dùng checkout development đang dirty; không coi đây là bản release đã phát hành.
- Các lượt đầu có thao tác nhập PIN của người dùng xen vào, lỗi harness và Android timeout chờ queue. Chỉ lượt chạy riêng đã pass mới được tính acceptance. Android từng phát hiện crash retry-scheduling khi journal lỗi; đã sửa và chạy lại.

| Gate | Trạng thái | Bằng chứng / giới hạn |
| --- | --- | --- |
| Journal ACK sau durable write | PASS | iOS 8 XCTest, Android 7 instrumentation; lỗi ghi không ACK, reopen giữ job |
| Login bypass → PIN sai/đúng → backend restore | PASS trên cả hai máy | Bypass refresh phiên đã lưu và khóa vault; không thay thế test logout thật |
| Bỏ qua → reopen → cài đặt → PIN | PASS trên cả hai máy | Dùng UI sample trên thiết bị |
| Khôi phục toàn bộ lịch sử | OPEN | iOS có 5 terminal marker gap mỗi lượt; Android cũng có `done_with_gaps/no_usable_archive` (gồm job/cycle đã resume); cần đối chiếu archive/material/wrap/generation từng epoch |
| Logout/login thật, thiết bị mới cài sạch | OPEN | Chưa chạy trong lượt bypass này |
| Offline/crash giữa login queue ở app thật; tải lớn | OPEN | SDK fixture đã test lỗi/restart; chưa chứng minh chaos và performance quy mô lớn trên app/backend thật |

Không suy ra nguyên nhân gap chỉ từ `no_usable_archive`: có thể thiếu archive hoặc archive/wrap/material không dùng được. Archive recovery giữ live MLS riêng; không đánh dấu gate toàn bộ lịch sử là xong.

Bằng chứng cuối: iOS `/private/tmp/archive-pin-login-ios-sdk-tests.log` (8/8), UI result bundles `archive-pin-login-ios-ui-run3.xcresult` và `archive-pin-login-ios-ui-skip1.xcresult`; Android `/private/tmp/archive-pin-login-android-tests6.log` (7/7) và build `archive-pin-login-android-build6.log`. [Báo cáo kiểm tra, chi phí và gate còn mở](../../../.task-artifacts/archive-pin-login-20261011/verification.md) liên kết với các report/marker đã lọc và manifest source/artifact. HEAD và staging của ba repo không đổi; không gộp các thay đổi dirty có sẵn vào kết luận release.

## Coverage từng epoch — 11/10/2026, research trên backend thật

Đọc journal hai máy (iOS bằng signed XCTest chỉ đọc: 1/1 pass), đối chiếu 15 channel generation 0 và ciphertext được phép trong epoch 0..1000. Query rộng limit500 trả hết một trang ở 11 channel và khớp ID với query từng epoch: 616 ciphertext. Bốn channel còn lại trả code 6, không coi là lịch sử rỗng. Availability có 218 epoch / 482 blob entries; mỗi máy có 218 checkpoint cùng cycle hiện tại.

Crypto offline WASM giải mã 612/616; 4 tin epoch 1 không được API trả archive/material. Xác thực metadata tái hiện đúng từng checkpoint: Android 581, iOS 604. Android loại 22 forward có AAD hợp lệ vì rebuild từ field forward không nằm trong payload, thêm 3 forward legacy AAD rỗng và 6 attachment thiếu AAD. iOS loại 8 attachment thiếu AAD ở epoch 3/5/11; Android lại chấp nhận 2 trong số đó khi manifest có assets nhưng thiếu attachment_id. Cần sửa parity validator, không nới AAD để tăng coverage.

Hai worker chỉ duyệt availability nên bỏ qua 4 epoch có ciphertext nhưng thiếu archive; ba channel vẫn báo `done`. Full-history gate tiếp tục OPEN. Lượt này không sửa code production, không publish plaintext mới vào DB; đối chiếu crypto/metadata offline với journal thật. [Báo cáo, bảng CSV/JSON từng epoch và chi phí/gate sửa tiếp](../../../.task-artifacts/archive-coverage-20261011/coverage.md). Chưa kiểm tra generation khác hoặc epoch >1000.

## APIN-RESTORE-001 — validator and coverage upgrade (2026-10-12)

The receive and archive application paths use the same bounded canonical AAD gate. Forward fields come from MLS-authenticated AAD and persist with the decoded message. Empty-AAD true legacy content is accepted with forward metadata removed. Presence of version/assets/attachment_id selects the manifest lane: malformed/mixed manifests and manifests without required AAD never fall back to legacy. New encrypted attachments require a canonical manifest/AAD before encryption; historical ciphertext is unchanged.

Decoded records without current validation proof are read as text only: attachment hydration and forward fields are quarantined in the affected record, while ciphertext and provider state remain intact. Android adds Room schema86 columns without deleting schema85 rows. Both SDKs guard archived publication against deleted/edited/newer ciphertext records and account/generation switches.

Epoch checkpoints bind validator2, coverage1 and repair cycle; parent coverage proof uses coverage2/census2 and generation/query scope. Old done without proof displays coverage_unknown and cannot bypass upgrade replay. Persisted per-ID outcomes distinguish persisted, safe_skipped and material/wrap/snapshot/crypto/schema/AAD/discovery failures. Per-epoch reason counters survive retry and reopen. Code6 remains permission_denied; PIN does not reconstruct missing epoch material. Settings reads durable history status after reopen rather than interpreting vault-ready as recovered history.

Only existing APIs are used. Page100 and opaque cursors are preserved with consistent range/generation; repeated/rejected cursors stop the scope with a durable reason. Census is capped at50 pages,5000 IDs,16MiB encoded responses and range width1000. Restore is capped at50 pages/epoch,5000 distinct IDs and1000 material+ciphertext calls/64MiB per scope pass; material8MiB and plaintext payload16MiB. Reaching a cap keeps coverage_unknown/discovery_budget; no sequential empty-epoch probing or limit500 workaround. HTTP runs outside the live provider lock. Cumulative JSON proofs have bounded checkpoint amplification under these caps; they are not an unbounded linear-write design.

AAD decoding uses O(L + K log K) time and O(L+K) memory, ≤1,376,289 bytes, canonical UTF-8 and sorted unique attachment UUIDs. Manifest validation is linear in payload/assets and precedes attachment fetch. Restore clears prepared material after each epoch. Benchmark fixture results are mobile tests, not server acceptance.

Current device evidence and open acceptance are maintained in the [Archive ledger](../../../bellboy/docs/todo/e2ee_archive_pin_restore_ledger.md) and [fresh evidence](../../../.task-artifacts/archive-restore-20261011/verification.md). Parent stays in_progress:8 historical manifests lack proof,4 messages lack material,4 scopes are denied, and full-history census remains unproven (including3 server cursor rejections). No backend/Web/shared-core changes are part of this upgrade.

`enqueueRestoreDurably(..., requestId: ...)` optionally binds initial login jobs to the saved request. Both samples pass that request UUID. Retrying a partially acknowledged login queue preserves existing cycle/cursors and terminal unknown/denied jobs; an explicit new request/repair creates a new incident. The optional field uses existing job JSON and does not change the native ABI/API server. Legacy callers keep the existing default behavior.


### Final restore behavior (APIN-RESTORE-001, 2026-10-12)

Optional enqueueRestoreDurably requestId preserves the same saved login request/range/generation cycle, including completed unknown scopes. Automatic code6 remains paused. Current-validator/coverage2 coverage_unknown jobs retain checkpoints for contained automatic ranges; explicit repair/new login, wider range or validator upgrade can retry. Covered done/done_with_gaps retain new-gap rescan behavior. Unknown never means recovered. The existing decoded ciphertext hash and authenticated metadata survive actual CoreData reopen.

Final evidence: [verification](../../../.task-artifacts/archive-restore-20261011/verification.md). Physical sample9 plus SDK44 tests prove the measured mobile corpus and current scope, not unbounded full history or server pagination correctness across all topics/spans/generations. APIN-RESTORE-001 remains in_progress while APIN-EXT-001/002/003 and the stated acceptance gates remain open.

### Continuation: decoded write/read provenance (2026-10-12)

<details>
<summary>Change log</summary>

- `2026-10-12`: Fence decoded writes/reads by current ciphertext and preserve stronger proof.
  - Reason: weak/stale cache could expose metadata or old attachment fallback after updates.
  - Integrator action: update SDK; local send/edit intents bind actual encrypted bytes, stale cache requires scoped repair.
  - Compatibility: existing ciphertextHash/schema/APIs; local pending staging readable, stored rows/ciphertext retained.

</details>

The central CoreData decoded writer refuses bound writes for deleted/currently different ciphertext and preserves a current bound row when an unbound staging write attempts to replace it. Bound cache reads compare their hash with the current parent ciphertext before exposing metadata/hydrating attachments. Received unbound encrypted cache is content-only; local pending intents remain readable. Received encrypted rows do not render old/envelope AttachmentDTO fallback. Scoped rows and ciphertext remain stored.

New send and edit intents store the hash of their actual encrypted bytes. The sender's cache metadata comes from canonical AAD used for that send, rather than unproven envelope fields. Existing pre-encrypt manifest/AAD gates remain required. This uses the existing ciphertextHash attribute, adds O(ciphertext bytes) hash work and bounded context reads, and introduces no schema, HTTP, native provider or journal algorithm change.

CoreData writer/read/quarantine regressions fail on milestone SDK16 and pass after correction;54 SDK tests pass, including outbound edit, native crypto and new sparse epoch/topic/query-span/generation fixtures. Read-only metadata export can also fingerprint durable ciphertext for rejected outcome IDs, capped at5000 IDs/500 query parameters; absent ciphertext stays an evidence limit. Fixtures and hashes do not establish server cursor/membership correctness or unbounded history. Latest [continuation gates/evidence](../../../.task-artifacts/archive-restore-continue-20261012/gates.md) retain APIN-EXT-003 Deferred and APIN-EXT-001/002 unresolved.
