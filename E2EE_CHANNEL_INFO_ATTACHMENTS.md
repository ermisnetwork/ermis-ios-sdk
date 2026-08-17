# E2EE attachments in Channel Info

Channel Info must select its attachment source from the channel's effective encryption mode.
Standard channels keep using `ChannelController.getAttachments`. Effectively encrypted channels
must use the E2EE projection API:

```swift
channelController.queryE2eeAttachments(
    limit: 50,
    cursor: nil
) { result in
    // Render page.items and pass page.nextCursor back unchanged for the next page.
}
```

The SDK calls `POST /v1/e2ee/channels/{type}/{id}/attachments/query`. The response is a visibility
and ordering projection only. For each projection page, the SDK fetches the required
`MessageDecryptDTO` rows in one Core Data read and joins every projection to the authenticated
attachment manifest already persisted after MLS decryption by exact message ID, attachment ID,
asset ID, asset kind, and ciphertext size. Corrupt durable payloads fail closed for their own rows;
they do not make another projection renderable and do not fail the rest of the page.

The encrypted manifest remains authoritative for filename, MIME type, plaintext size, media type,
dimensions, duration, CEK, nonce prefix, and hashes. A projection without an exact durable manifest
match is omitted and counted in `E2eeChannelAttachmentListPage.unavailableCount`; the SDK never
guesses metadata from an object key, URL, or extension.

Projection matching is forward-compatible only at the asset-kind boundary. iOS compares the known
`original`/`preview` rows by exact asset ID, kind, and ciphertext size, requires exactly one known
`original`, and rejects duplicate projected asset IDs. A future projection-only kind may be ignored,
but it can never supply display metadata or make an item renderable on its own.

## Pagination and ordering

- The default page size is 50 and the SDK clamps a caller-provided limit to `1...100`.
- `E2eeChannelAttachmentListCursor` is opaque. Pass `nextCursor` back unchanged.
- The cursor preserves Bellboy's exact `(created_at, attachment_id)` keyset.
- Results remain ordered by `created_at DESC, attachment_id DESC` and are deduplicated by
  attachment ID in the Channel Info consumer.
- A canceled or stale request generation must not overwrite a newer channel/tab refresh.

The SDK creates one `E2eeChannelAttachmentListController` per Channel Info screen and shares that
instance across the media, file, and voice tabs. The controller owns the only cursor chain for that
channel, plus pagination, retry, cancellation, generation checks, and immutable snapshots. A tab
created after the first page has loaded immediately derives its filtered rows from the current
snapshot instead of issuing a duplicate query. All three attachment tabs therefore preserve one
server order and one deduplicated attachment identity set.

The shared controller exposes one request phase for the projection stream. Previously loaded rows
survive a failed next page and a retryable failure resumes with the same opaque cursor. A terminal
failure is displayed without an automatic retry loop. Each tab independently derives its loading,
empty, retryable-error, and terminal-error presentation from the shared snapshot and its own
filtered rows. A failure can therefore add a scoped banner to the visible tab without clearing
already loaded media, file, or voice rows in any sibling tab.

## Tabs and media access

- `Ảnh, video` contains only manifest-classified image and video attachments.
- `Tệp tin` contains only manifest-classified generic files.
- `Tin nhắn thoại` contains only manifest-classified voice recordings.
- `Links` keeps its existing message/link data source and does not use attachment projections.

Voice recording classification is authenticated manifest metadata, not a filename or extension
guess. New iOS sends use the same contract as Web and put the following fields in the original
asset's encrypted `display` object:

```json
{
  "attachment_type": "voiceRecording",
  "duration": 2.5,
  "waveform_data": [0.1, 0.7]
}
```

The explicit `attachment_type` marker is canonical. For manifests emitted by the initial iOS
attachment implementation, the SDK temporarily accepts `audio/*` plus an encrypted `duration` as a
legacy voice marker because those builds omitted `attachment_type`. A generic audio attachment
without the explicit marker and without voice duration remains in `Tệp tin`; MIME alone must not
turn an uploaded song or audio file into a voice message.

Voice playback follows the same verified-original boundary as other E2EE originals. The timeline
never gives `ermis-e2ee-attachment://...` directly to the audio player. It first requests a fresh
download grant, downloads ciphertext, verifies declared cipher size and global SHA-256, verifies
and decrypts every AES-GCM frame into a protected local temporary file, and only then loads that
local audio URL. Grant URLs, content keys, nonce prefixes, and plaintext are not exposed by the
Channel Info model.

The timeline renders a ready voice recording as a compact play/pause control, bounded waveform,
and duration. If a compatible Web or legacy message has no waveform samples, iOS uses a fixed
presentation-only waveform; it does not modify or re-authenticate the manifest. Playback state is
matched to the attachment identity instead of comparing the opaque manifest URL with the decrypted
temporary file URL, so play, pause, and progress updates remain attached to the correct E2EE bubble.

Channel Info may automatically load only authenticated preview assets. Opening, saving, or sharing
an original must go through the SDK's download-grant flow, ciphertext-size and global SHA-256
verification, and per-frame AES-GCM verification/decryption. The public Channel Info model never
exposes content keys, nonce prefixes, presigned grant URLs, or background task tokens.

Preview loading follows the visible cell lifecycle:

- A media cell first uses the process-local decrypted preview cache. A cache miss joins or starts a
  single-flight request keyed by preview asset ID.
- The shared preview coordinator allows at most three preview download/decrypt operations at once.
  It never substitutes the original asset when a preview is absent.
- Leaving the viewport or reusing a cell cancels that cell's waiter. The underlying flight is
  canceled only when no timeline persistence target and no other visible waiter still needs it.
- Every flight has a generation ID. Completion from a canceled generation cannot consume or update
  a replacement flight for the same asset.
- A missing preview renders a small stable image/video placeholder. A corrupt or transiently failed
  preview renders an explicit retry affordance; neither state starts an original download.

Decoded preview bytes remain process-local and bounded by the E2EE preview cache. They are not
written to Core Data or a persistent plaintext cache and are rebuilt from authenticated preview
ciphertext after relaunch.

## Missing local state

The projection can refer to a message whose decrypted manifest is not available locally, for
example after local history cleanup or an incomplete repair. Such rows are deterministic
`unavailable` results, not a reason to replay an already-applied MLS ciphertext. A later scope sync
or message-page query may restore the durable message state; the next Channel Info refresh then
performs the projection-manifest join again.
