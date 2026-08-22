
# ErmisChat SDK for iOS

## [ErmisChat](https://ermis.network) home page

[![Platform](https://img.shields.io/badge/platform-iOS-orange.svg)](https://www.apple.com/ios) [![Languages](https://img.shields.io/badge/language-Swift-orange.svg)](https://www.swift.org) [![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-green.svg)](https://github.com/ermisnetwork/ermis-ios-sdk)

## Table of contents

1.  [Introduction](#introduction)
1.  [Requirements](#requirements)
1.  [Getting Started](#getting-started)
1.  [Features](#features)
1.  [Error codes](#error-codes)

## Introduction

The ErmisChat SDK for iOS allows you to integrate real-time chat into your client app with minimal effort.

## Requirements

The minimum requirements for ErmisChat SDK for iOS are:

- iOS 15 or higher
- Swift 5.10 or higher

### OpenMLS compatibility

The SDK pins `open-mls-ios` to the exact prerelease tag `0.1.0-m0.1`. This version contains the
AAD and plaintext-first persistence APIs required by the E2EE implementation. PIN/Epoch Archive
APIs are intentionally not exposed in this release.

Do not commit a local path dependency for release builds. When developing both repositories
locally, use SwiftPM editable mode:

```bash
swift package edit open-mls-ios --path ../open-mls-ios
```

## Getting started

This section shows you the prerequisites you needed to use the ErmisChat SDK for iOS. If you have any comments or questions regarding bugs and feature requests, please reach out to us.

## Step-by-Step Guide:

### Step 1: Generate API key and ProjectID

Before installing ErmisChat SDK, you need to generate an **API key** and **ProjectID** on the [Ermis Dashboard](https://ermis.network). This **API key** and **ProjectID** will be required when initializing the Chat SDK.

> **Note**: Ermis Dashboard will be available soon. Please contact our support team to create a client account and receive your API key. Contact support: [tony@ermis.network](mailto:tony@ermis.network)

### Step 2: Install the Chat SDK

You can add the ErmisChat SDK to your project IOS using Swift Package Manager.

**Swift Package Manager Instructions**

1. Open Xcode, go to your project's `General` settings tab, and select your project under `Project` in the left column.
2. Go to the Swift packages tab and click the + button.
3. When a pop-up shows, enter the package URL: https://github.com/ermisnetwork/ermis-ios-sdk
4. Swift Package Manager will automatically sets the dependency rule to "Up To Next Major" and install the latest version.

### Step 3: Create ErmisClient

ErmisClient is the root object representing a Ermis Chat.
When starting the app, you need to create an instance of `ErmisClient` first.
To do this, first using `apiKey` to create `ErmisClientConfig`. After that create `ErmisClient` with `config` and `token`.

```swift
import ErmisChat

let config = ErmisClientConfig(apiKeyString: apiKey)
let client = ErmisClient(config: config,
                         token: nil // If user isn't loggin we don't have token -> send nil 
                        )
```

### Step 4: Integrate Login via Wallet

To support Login via Wallet, ErmisChat needs to communicate with various Wallet applications. In this example, we use [Web3Modal](https://github.com/WalletConnect/web3modal) of `WalletConnect` to faciliate communication with wallet applications.

#### 4.1 Create a Challenge

First [install and setup](https://docs.walletconnect.com/appkit/ios/core/installation) `Web3Modal` library.

After install and setup Web3Modal, connect your app to a wallet application.

```swift
Web3Modal.present(from: self)
```

Web3Modal will show list of wallet for user to choose and connect. After users connect their wallet, the `sessionSettlePublisher` will publish an event. After this event emit, Call `startAuth` to create a challenge message.

```swift
Web3Modal.instance.sessionSettlePublisher.receive(on: DispatchQueue.main).sink { [weak self] session in
    let address = Web3Modal.instance.getAddress()
    guard !address.isEmpty else {
        return
    }
    let response = try await client.startAuth(with: address)
    let challengeMessage = response.challenge
    // Save nonce. It will need in step 4.3.
    self?.currentNonce = challengeMessage.nonce
}
```

#### 4.2 Sign wallet

After receiving the challenge message, you need to sign it with the wallet to obtain the signature. To do this, send `eth_signTypedData` request with the wallet address and challenge message as parameters.

```swift
let request = W3MJSONRPC.eth_signTypedData(
    address: address,
    message: challengeMessage
)

try await Web3Modal.instance.request(request)
```
> **Note**: This will send a sign message to user's wallet. To automatic switch to user wallet app, call `Web3Modal.instance.launchCurrentWallet`.

#### 4.3 Get authentication information

After user sign this message, the `sessionResponsePublisher` will emit an response. Use `signature` from response to call `walletAuthenticate` function.
This will return `AuthenticationPayload`. It contains `token`, and `refreshToken` which require to connect user.

```swift
 Web3Modal.instance.sessionResponsePublisher.receive(on: DispatchQueue.main).sink { [weak self] response in 
    switch response.result {
    case .response(let value):
        let signature = value.value as? String ?? 
        ((value.value as? JSONString)?.decode() as? String ) // If sign in with CoinBase
        ?? ""
        let walletSignResponse = await client.walletAuthenticate(with: signature,
                                                                 address: address,
                                                                 nonce: self.currentNonce ?? "") 
        // Init token from rawValue
        let token = try? Token(rawValue: walletSigninResponse.token)
        let refreshToken = walletSigninResponse.refreshToken
    case .error(let error):
    // Handle error 
    } 
 }
```

>**Note**: Web3Modal currently doesn't support `eth_signTypedData`, so we need to add it to `Web3Modal` SDK.

### Step 5: Connect User in SDK

Once initialized, you must specify the current user by calling the `connectUser` function:

```swift
// The SDK auto handle refreshToken eachtime it expired.
// But when the refreshToken also expired this closure will be call. 
let onRefreshTokenExpired: (() -> Void)? = {
    // You can handle yourself, like logout user ...
}
// This closure return eachtime token changed
let onAuthenticationChanged: (AuthenticationPayload) -> Void = { authenticationPayload in
    // Save new token
}
// This intance support refreshToken
let refreshTokenHelper = ErmisRefreshTokenHelper(token: token,
                                                 refreshToken: refreshToken,
                                                 onAuthorizationChanged: onAuthenticationChanged,
                                                 onRefreshTokenExpired: onRefreshTokenExpired)
// Connect user
client.connectUser(userInfo: userInfo,
                    refreshTokenHelper: refreshTokenHelper,
                    completion: completion)
```

To logout, call `logout` function in ```ErmisClient```

```swift
client.logout(completion: completion)
```

#### MLS device identity storage

For E2EE accounts, the SDK keeps one MLS `device_id` per user in a non-synchronizing Keychain
generic-password item protected with `AfterFirstUnlockThisDeviceOnly`. Normal logout preserves this
identity; only an explicit local E2EE purge removes it.

When upgrading from a version that stored device IDs in `UserDefaults`, the SDK copies the existing
per-user value to Keychain and writes the migration marker only after an exact read-back succeeds.
The legacy value remains available during the compatibility/rollback window. Before migration has
completed, a temporarily unavailable Keychain makes the SDK keep using the existing legacy value
without generating a replacement. After Keychain is authoritative, the same condition fails closed
because a restored legacy value may belong to another installation.

`ThisDeviceOnly` Keychain items do not migrate to another installation through backup/restore. Once
migration has completed, a missing Keychain item is therefore treated as a new installation: the SDK
creates a new device ID and the account must follow the normal MLS external-join flow. Applications
must not assume that restoring an encrypted device backup preserves the previous MLS device identity.

#### MLS provider database storage and migration

<details>
<summary>Change log</summary>

- `2026-08-08`: Locked the M1 incoming/outgoing persistence ordering and added a reproducible
  SIGKILL/relaunch verification harness.
  - Reason: same-process reload tests do not prove that SQLite/WAL state survives abrupt process
    termination.
  - Integrator action: run the harness on a booted simulator before changing MLS persistence or
    pending-send recovery.
  - Compatibility/default: production APIs and wire payloads are unchanged; the harness exists
    only in the test target.

</details>

The OpenMLS SQLite provider is stored under the app's Application Support directory, separately
from the Core Data chat cache. Its directory is excluded from backup and uses
`completeUntilFirstUserAuthentication` file protection on iOS. When an App Group is configured,
the same Application Support layout is used inside that container.

Upgrades copy the legacy provider database and any SQLite `-wal`/`-shm` sidecars into a staging
directory, reopen the staged database, and verify its stored identity and group IDs before promotion.
The migration marker is written only after verification. The legacy database remains untouched for
the rollback window; if copying or verification fails, the SDK continues with that legacy database
instead of opening a blank provider. A relaunch safely retries an interrupted migration.

At runtime, the SDK routes application decrypts, protocol processing, outgoing encryption,
membership commits, external joins, key-package generation, and group deletion through one internal
MLS mutation executor. It preserves FIFO ordering per effective MLS group and currently limits the
shared OpenMLS SQLite provider to one mutation at a time. The old decrypt-only queue is not used in
parallel. Share extensions and notification service extensions must hand work to the main app and
must not instantiate or mutate OpenMLS group state directly.

Incoming application processing is deferred: the SDK retains the exact plaintext, AAD, sender and
message epoch, commits plaintext to Core Data, and only then saves the updated OpenMLS receiver
state. Commit processing returns typed before/after epoch metadata; the durable commit proof and
exact target epoch are checked before its apply cursor advances. A Welcome whose group was already
persisted retries its historical-message normalization before cursor advancement, so a prior Core
Data failure cannot be hidden by relaunch. Standalone MLS proposals remain unsupported by Bellboy's
production flow and are rejected as repair issues rather than applied.

Outgoing E2EE text and edit sends follow the inverse durable ordering: create the local message and
stable ID first, encrypt on the MLS executor, save the sender state, synchronously persist the exact
ciphertext/epoch network intent, and only then begin HTTP. Relaunch and unknown HTTP-result recovery
reuse that exact intent. If a crash happens after sender-state save but before intent persistence,
the missing generation is abandoned and a later generation is encrypted from the durable sender
state. The composer clears only after the optimistic message write succeeds; database failure or
newer user input preserves the current draft. Slow-mode cooldown starts only after that local write.

To rerun the M1 process-crash gate, boot an iOS Simulator and pass its UDID:

```sh
./scripts/run-m1-e2ee-crash-harness.sh <booted-simulator-udid>
```

The four seed invocations intentionally report an XCTest process failure because each one sends
`SIGKILL` after its durable boundary. The script succeeds only when every following invocation
reopens the same on-disk OpenMLS/Core Data state and verifies TCR-005 through TCR-008.

#### Privacy-safe production diagnostics

SDK diagnostics expose only fixed lifecycle stages, bounded counters/timings, HTTP status, stable
API code, and allowlisted system-error domains with numeric codes. They never render request or
response bodies, WebSocket/SSE payloads, URL/query values, error descriptions, credentials, push
tokens, filenames/paths, presigned URLs, or user/channel/message/attachment/device identifiers.
Outbound E2EE stages use a process-local `trace_seq`; it is intentionally not a stable message or
channel correlation key and resets when the process restarts.

`URLRequest.cURL()` remains available for source compatibility, but production request execution
does not invoke it. Host applications should apply the same rule to their own logs and must not
wrap SDK errors by printing `localizedDescription`, because provider/server descriptions are not
part of the privacy-safe diagnostic contract. Background transfer `taskDescription` and the
before-first-unlock callback journal contain only random UUID task tokens plus bounded transfer
status/count metadata.

#### E2EE attachment original download and export

An E2EE attachment's `remoteURL` is an opaque SDK reference, not a storage URL. Do not pass it to a
generic downloader, `AVPlayer`, Photos, a document picker, or a share sheet. Resolve an original
through the SDK so its declared ciphertext size and global SHA-256 are checked before authenticated
frame decryption exposes a protected local file:

```swift
let lease = try await client.acquireAttachmentForViewing(attachment) { progress in
    // `fractionCompleted` is network ciphertext progress only. Keep processing UI visible while
    // the phase is `.verifying`, `.waitingForUnlock`, or `.decrypting`.
    updateTransferUI(progress)
}
defer { lease.release() }

let localURL = lease.localURL
// Keep `lease` alive while AVPlayer, WebKit, Photos, Files, or the share sheet reads `localURL`.
```

The foreground resolver coalesces requests for the same asset and bounds interactive full-file
downloads. Cancelling a viewer releases only that viewer; the underlying request is cancelled when
no requester remains. A download-grant-related `401`/`403` obtains one fresh grant and restarts the
whole GET. It never trusts an unproven partial response. Plaintext is atomically published only after
all size/hash/frame-GCM checks pass.

If protected data is unavailable after the ciphertext has been downloaded and globally verified,
the resolver reports `.waitingForUnlock`, keeps that verified ciphertext in protected SDK staging,
and creates no plaintext. It automatically continues authenticated frame decryption after the device
is unlocked. A foreground download that is still partial when the process is killed is not yet a
durable resume point; process-death recovery for partial bytes belongs to the background-download
journal/reconciliation milestone.

Every viewer/exporter must own a separate `E2eeAttachmentOriginalLease`. Releasing one lease cannot
delete a plaintext file while another gallery, Save, or Share operation still uses it. After the last
lease is released, the SDK removes that plaintext original. The older
`prepareAttachmentForViewing` URL-only API remains source-compatible, but because it cannot observe
consumer lifetime, its plaintext is retained until client shutdown; new integrations should use the
lease API.

The built-in gallery keeps standard attachments on the existing download path. For opaque E2EE
attachments, Save and Share consume only the verified local file. Save owns an independent request,
whereas Share is viewer-scoped and is cancelled if the gallery closes. This foreground Save remains
process-scoped; durable background download/export recovery is a separate follow-up milestone.

The built-in file preview follows the same boundary: an opaque E2EE file reference is resolved to a
size/SHA/frame-GCM-verified local file before WebKit preview or Files export. The opaque URL must not
be handed to `WKWebView` or the standard attachment downloader (`NSURLErrorUnsupportedURL`).

The message long-press **Download** action uses this same verified-original boundary. For an E2EE
file it resolves the opaque reference first and presents the verified plaintext copy in the Files
document picker; it never forwards `ermis-e2ee-attachment://...` to the generic HTTP downloader.
Standard attachment downloads keep their existing behavior.

#### File versus video send intent

Selecting media through Photos creates an inline image/video attachment. Selecting the same bytes
through Files keeps document intent by default: the message renders as a file and opens only through
the verified-original download path. For a video-like document, the composer also offers **Send as
video**. That option performs a bounded local AVFoundation capability check before creating a video
bubble, encrypted preview, or player. A container or codec that the current device cannot play is
never silently promoted; the user may still send its original bytes as a file.

The encrypted manifest authenticates `attachment_type` independently from `mime_type`. Updated iOS
and Web receivers treat `file`, `video`, `image`, and `voiceRecording` as authoritative, while old
manifests without the marker retain MIME-based compatibility. Extensions such as MKV, WebM, raw HEVC,
and H.265 are recognized as video candidates so the choice is available, but recognition is not a
claim of native playback support. HEVC inside a device-supported MOV/MP4 container may pass the probe;
unsupported MKV/codecs remain lossless downloadable files unless a future decoder/transcode subsystem
is introduced explicitly.

#### E2EE video range playback

The built-in gallery uses authenticated byte-range playback for every opaque E2EE video by
default. Selection does not depend on file size or duration: AVFoundation requests plaintext
ranges, the SDK maps them to framed ciphertext, and only verified frames enter the bounded playback
cache. The custom asset URL carries a sanitized media extension and its content UTI is resolved
from authenticated manifest metadata first, then attachment metadata, with an MP4 video fallback;
this prevents missing MIME metadata from forcing extension-less media probing. Explicit Download,
Save, Share, and Forward operations still acquire a verified whole original because their consumers
require a complete local file.

Hosts can retain a per-client rollback while completing their device matrix:

```swift
var config = ErmisClientConfig(
    apiKeyString: apiKey,
    endpointEnviroment: environment
)
config.isE2eeRangeStreamingEnabled = false
```

At process level, an absent `ERMIS_E2EE_RANGE_STREAMING_ENABLED` value uses the default-on policy;
`1` explicitly enables it, while any other explicit value disables it. Range authorization,
response validation, or authenticated-frame failures transparently continue from the verified
whole-original fallback. Keep the fallback and rollback controls available until real R2/device
startup, seek, lifecycle, and network-recovery gates pass.

#### E2EE attachments in Channel Info

Channel Info for an effectively encrypted channel must use Bellboy's E2EE attachment projection
query and join each projection to the durable decrypted message manifest. The encrypted manifest,
not the projection, object key, URL, or filename extension, is authoritative for display metadata
and image/video/file/voice classification. Visible cells may resolve only the encrypted preview;
opening, saving, or sharing an original must use the verified-original pipeline above.

See [E2EE Channel Info attachment integration](E2EE_CHANNEL_INFO_ATTACHMENTS.md) for pagination,
join validation, unavailable-state, preview, and original-download requirements.

<br />

### Step 6: Sending your first message

Now that the Chat SDK has been imported, you're ready to start sending messages.
Here are the steps to send your first message using the Chat SDK:

#### 6.1 Query users

Get the users in your project to create a direct message:

```swift
    let userSearchController = client.userSearchController()
    userSearchController.search(term: nil, completion: nil)
```

Then you can get observer users list in `UserSearchControllerDelegate`:

```swift
protocol UserSearchControllerDelegate {
    func controller(
        _ controller: UserSearchController,
        didChangeUsers changes: [ListChange<ChatUser>]
    )
}
```

> **Note**: To see all about query users, see: [User management](#user-management)

#### 6.2 Create a new channel

Next step, we need to create new `ChannelController`. This object is a controller class which alows mutating and observing changes of a channel.
We can create two type of channelController: `messaging` or `team`

**1. Create a channel controller for a `messaging`**

The `messaging` channel have only two members, and uniquely identified by its members.

```swift
let channelController = try client.channelController(createDirectMessageChannelWith: [chatUser.id],
                                                     name: nil,
                                                     imageURL: nil)
                                            
// Call synchronize to create channel:

channelController.synchronize { [weak self] error in
    ...
}
```

**2. Create a channel controller for a `team`**

```swift
let channelController = try client.channelController(
    createChannelWithId: .init(type: .team,
                               projectId: projectId, // The projectId, you can get from ErmisClient.
                               id: String.randomId),
    name: name, // Name of the channel
    members: memberIds // List memberIds, the member will receive invited to join this channel.
)

// Call synchronize to create channel:

Call `synchronize` to create directChannel

channelController.synchronize { [weak self] error in
    ...
}
```

#### 6.3 Send messages

To send a message, use the `createNewMessage` function from the `channelController`:
```swift
channelController.createNewMessage(text: "New message")

// Call synchronize to create message on backend
channelController.synchronize { [weak self] error in
    ...
}
```

<br />

## Features

1. [User management](#user-management)
1. [Channel management](#channel-management)
1. [Message management](#message-management)
1. [Events](#events)

### User management

#### **1. Get users with UserIDs**

```swift
class ChannelController {
    public func fetchUsers(with ids: [String],
                           projectId: String,
                           completion: @escaping (Result<[ChatUser], Error>) -> Void) {}
}
```

**Parameters:**

|  **Name**  |               **Type**              | **Required** | **Description**                                                      |
|:----------:|:-----------------------------------:|:------------:|----------------------------------------------------------------------|
|     ids    |               `Array`               |     true     | A list of userId of user.                                            |
| completion | `Result<[ChatUser],Error>) -> Void` |     false    | Called when the API call is finished. Called with `Error` if failed. |

#### **2. Search users**

To fetch/search user, we use `UserSearchController`. We create this intance from `ErmisClient`. 

```swift
let userSearchController = client.userSearchController()
```
Then call funtion `search` to search user

```swift
func search(term: String,
            limit: Int = 25,
            offset: Int = 0,
            completion: @escaping (Result<ChannelSearchPayload, Error>) -> Void)
```

 **Parameters:**

|  **Name**  |           **Type**           | **Required** | **Description**                                                      |
|:----------:|:----------------------------:|:------------:|----------------------------------------------------------------------|
|     term   |            `String`          |     false    | Search term. If empty string or `nil`, all users are fetched.        |
| completion | `(_ error: Error?) -> Void)` |     false    | Called when the API call is finished. Called with `Error` if failed. |

To loadmore using `loadMoreUsers` function:

```swift
func loadMoreUsers(
        limit: Int = 25,
        completion: ((Error?) -> Void)? = nil
    )
```

 **Parameters:**

|  **Name**  |           **Type**           | **Required** | **Description**                                                      |
|:----------:|:----------------------------:|:------------:|----------------------------------------------------------------------|
|    limit   |             `Int`            |     false    | Limit for page size.                                                 |
| completion | `(_ error: Error?) -> Void)` |     false    | Called when the API call is finished. Called with `Error` if failed. |

We can get users list from `users` variable, we also can observe the changed of `users` by using in `UserSearchControllerDelegate`

```swift
protocol UserSearchControllerDelegate {
    func controller(
        _ controller: UserSearchController,
        didChangeUsers changes: [ListChange<ChatUser>]
    )
}
```

All your contact ids will be store in `friendContactIds`, this value will set after you call `search` function.

#### **3. Update personal profile**

Using `CurrentUserController` function allows you to observe and mutate the current user's profile.

You can create it from `ErmisClient`:

```swift
let currentUserController = client.currentUserController()
```

To update user's profile, using `updateUserData` function:

```swift
func updateUserData(
    name: String? = nil,
    imageData: Data? = nil,
    completion: ((Error?) -> Void)? = nil
)
```

 **Parameters:**

|  **Name**  |           **Type**           | **Required** | **Description**                                                      |
|:----------:|:----------------------------:|:------------:|----------------------------------------------------------------------|
|    name    |           `String`           |     false    | Optionally provide a new name to be updated.                         |
|  imageData |            `Data`            |     false    | Optionally provide a new image data to be updated.                   |
| completion | `(_ error: Error?) -> Void)` |     false    | Called when the API call is finished. Called with `Error` if failed. |

To observing current user's profile, first call `synchronize` function then observing changes by implement `CurrentUserControllerDelegate`.

<br />

### Channel management

#### 1. Query channel list

After creating a channel, use `ChannelListController` to retrieve the list of joined channels or invited channels.

`ChannelListController` is the object that manages channel list.
You can initialize it from `ErmisClient`. See the following examples:

**1.1. Joined channel list**

To retrieve the list of channels that the user has joined, use the `ChannelListQuery`. This function manages the list of channels and allows you to query the joined channels .
```swift
let channelListQuery: ChannelListQuery = .init(
    filter: .joinedChannels(memberId: userId,
                            projectId: projectId),
    sort: [
        .init(key: .lastMessageAt),
        .init(key: .updatedAt)
    ]
)

guard let channelListController = chat.channelListController(query: channelListQuery) else {
    return
}
```

**1.2. Invited channel list**

```swift
let invitedChannelListQuery = ChannelListQuery(filter: .invitedChannels(memberId: userId,
                                                                        projectId: projectId),
                                               sort: [.init(key: .createdAt,
                                                      isAscending: true)]
)

guard let invitedChannelController = chat.invitedChannelListController(query: invitedChannelListQuery) else {
    return
}
```

After initialization, call the `synchronize` function to retrieve all channels match your query:

```swift
controller.synchronize()
```

To handle changes when channels are updated, set `delegate` of `ChannelListController` to your class and make it conform to the `ChannelControllerDelegate` protocol.

#### 2. Create a channel

**2.1. Create a channel controller for a `messaging`**

```swift
let channelController = try client.channelController(createDirectMessageChannelWith: [chatUser.id],
                                                     name: nil,
                                                     imageURL: nil)
                                            
// Call synchronize to create channel:

channelController.synchronize { [weak self] error in
    ...
}
```

**2.2. Create a channel controller for a `team`**


```swift
let channelController = try client.channelController(
    createChannelWithId: .init(type: .team,
                               projectId: projectId, // The projectId, you can get from ErmisClient.
                               id: String.randomId),
    name: name, // Name of the channel
    members: memberIds // List memberIds, the member will receive invited to join this channel.
)

// Call synchronize to create channel:

Call `synchronize` to create directChannel

channelController.synchronize { [weak self] error in
    ...
}
```

#### 3. Accept/Reject invite:

To accept/reject an invitation, use `acceptInvite`/`rejectInvite` function in `ChannelController`

```swift
class ChannelController {
    // Accept invite
    func acceptInvite(completion: ((Error?) -> Void)? = nil) {}
}
```

 **Parameters:**

|  **Name**  |       **Type**      | **Required** | **Description**                                                      |
|:----------:|:-------------------:|:------------:|----------------------------------------------------------------------|
| completion | `(Error?) -> Void)` |     false    | Called when the API call is finished. Called with `Error` if failed. |


```swift
class ChannelController {
    // Accept invite
    func rejectInvite(completion: ((Error?) -> Void)? = nil) {}
}
```

 **Parameters:**

|  **Name**  |       **Type**      | **Required** | **Description**                                                      |
|:----------:|:-------------------:|:------------:|----------------------------------------------------------------------|
| completion | `(Error?) -> Void)` |     false    | Called when the API call is finished. Called with `Error` if failed. |

#### 4. Query a channel

`ChannelController` is a controller class that allows you to mutate and observe changes in a specific chat channel.

You can initialize the `channelController` from `ErmisClient`.

```swift
func channelController(
    for cid: ChannelId,
    channelListQuery: ChannelListQuery? = nil,
    messageOrdering: MessageOrdering = .topToBottom
)
```
**Parameters:**

|     **Name**     |       **Type**      | **Required** | **Description**                                                      |
|:----------------:|:-------------------:|:------------:|----------------------------------------------------------------------|
|        cid       |     `ChannelId`     |     true     | The id of the channel this controller represents.                    |
| channelListQuery |  `ChannelListQuery` |     false    | The channel list query this controller is part of.                   |
|  messageOrdering |  `MessageOrdering`  |     false    | Describes the ordering the messages are presented.                   |

#### 5. Query Message List

**5.1 Load the First page of messages** 

To retrieve the first page of messages for a  channel, use the information from the current `channelQuery`:

```swift
public func loadFirstPage(_ completion: ((_ error: Error?) -> Void)? = nil)
```

**Parameters:**

|  **Name**  | **Type** | **Required** | **Description**                                                                                                                     |
|:----------:|:--------:|:------------:|-------------------------------------------------------------------------------------------------------------------------------------|
| completion |  Closure |     false    | The completion. Will be called when the network request is finished. If request fails, the completion will be called with an error. |

**5.2 Load Previous Messages**

To retrieve previous messages in a channel, use the `limit` parameter to specify how many messages to load before the message with the ID `messageId`:

```swift
public func loadPreviousMessages(
        before messageId: MessageId? = nil,
        limit: Int? = nil,
        completion: ((Error?) -> Void)? = nil
    )
```

**Parameters:**

|  **Name**  |  **Type** | **Required** | **Description**                                                                                                                     |
|:----------:|:---------:|:------------:|-------------------------------------------------------------------------------------------------------------------------------------|
|  messageId | MessageId |     false    | ID of the last fetched message. You will get messages  ` older ` than the provided ID.                                              |
|    limit   |    Int    |     false    | Limit for page size. By default it is 25.                                                                                           |
| completion |  Closure  |     false    | The completion. Will be called when the network request is finished. If request fails, the completion will be called with an error. |

**5.3 Load Next Messages**

To retrieve the next set of messages in a channel, use the `limit` parameter to specify how many messages to load after the messages to load afer the mesage with the ID `messageId`:

```swift
    public func loadNextMessages(
        after messageId: MessageId? = nil,
        limit: Int? = nil,
        completion: ((Error?) -> Void)? = nil
    )
```

**5.4 Load Message Around ID**

To retrieve messages around a specific message, use the `limit` parameter to specify how many messages to return before and after the message with the ID `messageId`

```swift
loadPageAroundMessageId(_ messageId: MessageId,
                        limit: Int? = nil,
                        completion: ((Error?) -> Void)? = nil)
```

#### 6. Setting a channel

The channel settings feature allows users to customize channel attributes such as name, description, membership permissions, and notification settings to suit their communication needs.


**6.1. Edit channel information (name, avatar, description)**

You can edit the name, avatar, description of a channel by using the function `updateChannel`

```swift
channelController.updateChannel(name: updatedName,
                                description: updatedDescription,
                                imageURL: updatedAvatarUrl) { [weak self] error in
    ...                           
}
```
**Parameters:**

|   **Name**  |       **Type**      | **Required** | **Description**                                                                    |
|:-----------:|:-------------------:|:------------:|------------------------------------------------------------------------------------|
|     name    |       `String`      |     false    | The updated name of channel, if name doesn't changed, just send nil.               |
| description |       `String`      |     false    | The updated description of channel, if description doesn't changed, just send nil. |
|   imageUrl  |       `String`      |     false    | The updated avatar url of channel, if avatar dessn't changed, just send nil.       |

**Note**: To upload avatar, see [Upload file](#2-upload-file)

**6.2. Adding & Removing Channel Members**

Add or remove members:

```swift
// Add members
channelController.addMembers(userIds: [member.userId]) { [weak self] error in
    ...
}
// Remove members
channelController.removeMembers(userIds: [member.userId]) { [weak self] error in
    ...
}
```
**Parameters:**

|   **Name**  |  **Type**  | **Required** | **Description**                                                                    |
|:-----------:|:----------:|:------------:|------------------------------------------------------------------------------------|
|   userIds   | `[String]` |     true     | Set of member id to add/ remove.                                                   |

To get list of suggestion members, use `ChannelMemberListController`

```swift

let channelMemberQuery = ChannelMemberListQuery(
    cid: cid,
    filter: .autocomplete(.name, text: term),
    sort: [.init(key: .name, isAscending: true)]
)

client.memberListController(query: channelMemberQuery)
```
**Parameters:**

|  **Name**  |   **Type**  | **Required** | **Description**                                                              |
|:----------:|:-----------:|:------------:|------------------------------------------------------------------------------|
|     cid    | `ChannelId` |     true     | ChannelId of channel.                                                        |
|    term    |   `String`  |     true     | Search string to filter member.                                              |

Then track delegate of `ChannelMemberListController` to observer list channel members:

```swift
func memberListController(
    _ controller: ChannelMemberListController,
    didChangeMembers changes: [ListChange<ChannelMember>]
)
```

**6.3. Adding & Removing Moderators to a Channel**

To change the role of members, use `promotes/demote members`:

```swift
// Promote members
func promoteMembers(_ members: [String], completion: ((Error?) -> Void)?)
// Demote members
func demoteMembers(_ members: [String], completion: ((Error?) -> Void)?)
```

**Parameters:**

|  **Name**  |       **Type**       | **Required** | **Description**                                                              |
|:----------:|:--------------------:|:------------:|------------------------------------------------------------------------------|
|  memberIds |      `[String]`      |     true     | The list of member id that will be promoted/demoted                          |
| completion | `((Error?) -> Void)` |     false    | Called when the API call is finished. Called with `Error` if failed.         |

**6.4. Ban & Unban Channel Members**

The ban and unban feature allows administrators to block or unblock members with the “member” role in a channel, managing their access rights.
```swift
// Ban members
func banMembers(_ members: [String], completion: ((Error?) -> Void)?)
// Unban members
func unbanMembers(_ members: [String], completion: ((Error?) -> Void)?)
```

**Parameters:**

|  **Name**  |       **Type**       | **Required** | **Description**                                                              |
|:----------:|:--------------------:|:------------:|------------------------------------------------------------------------------|
|  memberIds |      `[String]`      |     true     | The list of member id that will be banned/unbanned                           |
| completion | `((Error?) -> Void)` |     false    | Called when the API call is finished. Called with `Error` if failed.         |

**6.5. Channel Capabilities**

This feature allows owner to configure permissions for members with the “member” role to send, edit, delete, and react to messages, ensuring chat content control.
Permissions is saved as `memberCapabilities` in channel.
We can add/remove permissions:

```swift
func updateChannelCapabilities(in cid: ChannelId,
                                   removedCapabilities: [String] = [],
                                   addedCapabilities: [String] = [],
                                   completion: ((Error?) -> Void)?)
```

**Parameters:**

|       **Name**      |      **Type**      | **Required** | **Description**                                                      |
|:-------------------:|:------------------:|:------------:|----------------------------------------------------------------------|
|         cid         |     `ChannelId`    |     true     | Channel Id of the channel                                            |
| removedCapabilities |     `[String]`     |     false    | Capabilities you want to adding                                      |
|  addedCapabilities  |     `[String]`     |     false    | Capabilities you want to removing                                    |
|      completion     | `(Error?) -> Void` |     false    | Called when the API call is finished. Called with `Error` if failed. |

**Capabilities:**

| **Name**           | **What it indicates**                           |
|--------------------|-------------------------------------------------|
| send-message       | Ability to send a message                       |
| update-own-message | Ability to update own messages in the channel   |
| delete-own-message | Ability to delete own messages from the channel |
| send-reaction      | Ability to send reactions                       |

**6.6. Query attachments in a channel**

This feature allows users to view all media files shared in a channel, including images, videos, and audio.
Call this API to retrieve all attachments, then filter them locally to obtain the result you need.


```swift
func getAttachments(in cid: ChannelId,
                    completion: @escaping (Result<ChannelAttachmentListPayload, Error>) -> Void)
```

**Parameters:**

|  **Name**  |                         **Type**                         | **Required** | **Description**                                                                                                                                   |
|:----------:|:--------------------------------------------------------:|:------------:|---------------------------------------------------------------------------------------------------------------------------------------------------|
|     cid    |                        `ChannelId`                       |     true     | Channel Id of the channel                                                                                                                         |
| completion | `(Result<ChannelAttachmentListPayload, Error >) -> Void` |     false    | Called when the API call is finished. Called with Error if the remote update fails. Called with ChannelAttachmentListPayload if api call success. |

<br />

### Message management

#### 1. Sending a message

This feature allows user to send a message to a specified channel or DM:

**Sending message**
To send a message, call the `createNewMessage` function from the `ChannelController` object. This will create a new message locally.

```swift
func createNewMessage(
        messageId: MessageId? = nil,
        text: String,
        isSilent: Bool = false,
        attachments: [AnyAttachmentPayload] = [],
        mentionedUserIds: [UserId] = [],
        quotedMessageId: MessageId? = nil,
        completion: ((Result<MessageId, Error>) -> Void)? = nil
) 
```

**Parameters:**

|     **Name**     |               **Type**               | **Required** | **Description**                                                                                                                                                             |
|:----------------:|:------------------------------------:|:------------:|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     messageId    |              `MessageId`             |     false    | The id for the sent message. By default, it is automatically generated by Ermis.                                                                                            |
|       text       |               `String`               |     true     | Text of the bmessage.                                                                                                                                                       |
|     isSilent     |                `Bool`                |     false    | A flag indicating whether the message is a silent message. Silent messages are special messages that don't increase the unread messages count nor mark a channel as unread. |
|    attachments   |       `[AnyAttachmentPayload]`       |     false    | An array of the attachments for the message. Note : can be built-in types, custom attachment types conforming to AttachmentEnvelope protocol.                               |
| mentionedUserIds |              `[UserId]`              |     false    | List user id was mentioned.                                                                                                                                                 |
|  quotedMessageId |              `MessageId`             |     false    | An id of the message new message quotes. (inline reply).                                                                                                                    |
|    completion    | `(Result<MessageId, Error>) -> Void` |     false    | Called when saving the message to the local DB finishes. Called with `Error` if failed.                                                                                     |

Then call `synchronize` to sync new message to backend.

```swift
func synchronize(_ completion: ((_ error: Error?) -> Void)? = nil)
```

**Parameters:**

|  **Name**  |      **Type**      | **Required** | **Description**                                                                                                                                   |
|:----------:|:------------------:|:------------:|---------------------------------------------------------------------------------------------------------------------------------------------------|
| completion | `(Error?) -> Void` |     false    | Called when the API call is finished. Called with `Error` if failed.                                                                              |

**Sending status**

You can track sending status of `ChatMessage` with instance `localState` and `readByCount`.
Here is the example:

```swift
var deliveryStatus: MessageDeliveryStatus? {
    guard isSentByCurrentUser else {
        // Delivery status exists only for messages sent by the current user.
        return nil
    }

    guard type == .regular || type == .reply else {
        // Delivery status only makes sense for regular messages and thread replies.
        return nil
    }

    switch localState {
    case .pendingSend, .sending, .pendingSync, .syncing, .deleting:
        return .pending
    case .sendingFailed, .syncingFailed, .deletingFailed:
        return .failed
    case nil:
        return readByCount > 0 ? .read : .sent
    }
}
```

#### 2. Upload files

This feature allows user to upload a file to the system. Maximum file size is 2GB
To upload channel attachment, call `uploadAttachment` function in `ChannelController` object.

Standard-channel uploads use the legacy Bellboy multipart proxy by default. Hosts can opt in to
Bellboy's direct `presign -> storage PUT -> confirm` flow while the rollout matrix is being
validated:

```swift
var config = ErmisClientConfig(
    apiKeyString: apiKey,
    endpointEnviroment: endpointEnvironment
)
config.isStandardPresignedUploadEnabled = true
config.allowsLegacyStandardUploadFallback = true
```

The direct storage request is file-backed and contains only storage-required headers; SDK API
credentials, cookies, and Bellboy-specific headers are never copied to the presigned URL. Legacy
fallback is attempted only when presign fails before a storage PUT could have succeeded. Set
`allowsLegacyStandardUploadFallback` to `false` to fail closed during rollout. A configured
`customUploader` or `customUploadClient` keeps precedence over this built-in selection.

For standard video messages, the original video and generated thumbnail are uploaded and confirmed
as two distinct objects. The message attachment is marked uploaded only after both confirms succeed;
the visible progress reserves the final 10% for thumbnail upload and confirmation.

```swift
public func  uploadAttachment(
    localFileURL: URL,
    type: AttachmentType,
    progress: ((Double) -> Void)? = nil,
    completion: @escaping ((Result<UploadedAttachment, Error>) -> Void)
)
```

**Parameters:**:

|   **Name**   |                    **Type**                   | **Required** | **Description**                                                                                                          |
|:------------:|:---------------------------------------------:|:------------:|--------------------------------------------------------------------------------------------------------------------------|
| localFileURL |                     `URL`                     |     true     | Local URL of the file. Note: With image file, we can use temporaryLocalFileUrl function to create localURL from UIImage. |
|     type     |                `AttachmentType`               |     true     | The attachment type.                                                                                                     |
|   progress   |              `((Double) -> Void)`             |     false    | Upload progress closure.                                                                                                 |
|  completion  | `(Result<UploadedAttachment, Error>) -> Void` |     false    | Called when the API call is finished. Called with `Error` if failed.                                                     |

#### 3. Edit messages

To edit a message, you need to call `editMessage` function in `MessageController` object:

```swift
func editMessage(
        text: String,
        skipEnrichUrl: Bool = false,
        attachments: [AnyAttachmentPayload] = [],
        completion: ((Error?) -> Void)? = nil
)
```

|    **Name**   |                    **Type**                   | **Required** | **Description**                                                                                       |
|:-------------:|:---------------------------------------------:|:------------:|-------------------------------------------------------------------------------------------------------|
|      text     |                    `String`                   |     true     | The updated message text.                                                                             |
|  attachments  |            `[AnyAttachmentPayload]`           |     false    | An array of the attachments for the message.                                                          |
|   completion  |               `(Error?) -> Void`              |     false    | Called when the API call is finished. Called with `Error` if failed.                                  |


#### 4. Delete messages

To delete an existing message, you need to call `deleteMessage` function in `MessageController`:

```swift
public func deleteMessage(onlyForMe: Bool, completion: ((Error?) -> Void)? = nil)
```

**Parameters:**

|  **Name**    |      **Type**      | **Required** | **Description**                                                                               |
|:----------:  |:------------------:|:------------:|-----------------------------------------------------------------------------------------------|
|  onlyForMe   |       `Bool`       |     false    | A Boolean value to determine if the message will be delete for current user or for all users. |
|  completion  | `(Error?) -> Void` |     false    | Called when the API call is finished. Called with `Error` if failed.                          |

#### 5. Search messages

This feature allows user to search for a specific message in a channel:
```swift
public
func search(term: String,
            limit: Int = 25,
            offset: Int = 0,
            completion: @escaping (Result<ChannelSearchPayload, Error>) -> Void)
```
**Parameters:**

|  **Name**  |                     **Type**                    | **Required** | **Description**                                                      |
|:----------:|:-----------------------------------------------:|:------------:|----------------------------------------------------------------------|
|    term    |                     `String`                    |     true     | The string text to search.                                           |
|    limit   |                      `Int`                      |     false    | Max number of result items per page.                                 |
|   offset   |                      `Int`                      |     false    | Offset message index.                                                |
| completion | `(Result<ChannelSearchPayload, Error>) -> Void` |     false    | Called when the API call is finished. Called with `Error` if failed. |

#### 6. Unread messages

The Unread Message Count indicates how many messages were received wwhile a user was offline. After reconnecting or logging in, user can view the total number of missed messages in a channel or DM.

**6.1 Get unread messages count for channels**

To get unread message count, using `unreadCount` in `Channel`

```swift
let unreadCount = channel.unreadCount
```

**6.2 Marking a channel as read**

Marks the channel as read.

```swift
public func markRead(completion: ((Error?) -> Void)? = nil)
```

**Parameters:**

|  **Name**  |                **Type**            | **Required** | **Description**                                                      |
|:----------:|:----------------------------------:|:------------:|----------------------------------------------------------------------|
| completion | `(Result<Channel, Error>) -> Void` |     false    | Called when the API call is finished. Called with `Error` if failed. |

#### 7. Reactions

The Reaction feature allows users to send, manage reactions on messages, and remove reactions when necessary.


```swift
//Add reaction
public func addReaction(
    _ type: MessageReactionType,
    completion: ((Error?) -> Void)? = nil
)
// Remove reactions
public func deleteReaction(
    _ type: MessageReactionType,
    completion: ((Error?) -> Void)? = nil
)
```

**Parameters:**

|  **Name**  |        **Type**       | **Required** | **Description**                                                      |
|:----------:|:---------------------:|:------------:|----------------------------------------------------------------------|
|    type    | `MessageReactionType` |     true     | The reaction type.                                                   |
| completion |   `(Error?) -> Void`  |     false    | Called when the API call is finished. Called with `Error` if failed. |

#### 8. Typing Indicators
Typing indicators feature lets users see who is currently typing in the channel
```swift
class ChannelController {
    // Start typing
    public func sendStartTypingEvent(completion: ((Error?) -> Void)? = nil)
    // Stop typing
    public func sendStopTypingEvent(completion: ((Error?) -> Void)? = nil)  
}                              
```

**Parameters:**

|  **Name**  |        **Type**       | **Required** | **Description**                                                      |
|:----------:|:---------------------:|:------------:|----------------------------------------------------------------------|
|    type    | `MessageReactionType` |     true     | The reaction type.                                                   |
| completion |   `(Error?) -> Void`  |     false    | Called when the API call is finished. Called with `Error` if failed. |

To track users currently typing in a channel, use `typingUsersPublisher` in the `ChannelController`

#### 9. System messages

Below you can find the complete list of system message that are returned by messages from channel. You can define from syntax message by description.

| Name                            | Syntax                   | Description                                       |
| :------------------------------ | :----------------------- | :------------------------------------------------ |
| UpdateChannelName               | `1 user_id channel_name` | Member X updated name of channel                  |
| UpdateChannelImage              | `2 user_id`              | Member X updated image of channel                 |
| UpdateChannelDescription        | `3 user_id`              | Member X updated description of channel           |
| MemberRemoved                   | `4 user_id`              | Member X has been removed from this channel       |
| MemberBanned                    | `5 user_id`              | Member X has been banned from interacting         |
| MemberUnbanned                  | `6 user_id`              | Member X has been unbanned from interacting       |
| MemberPromoted                  | `7 user_id`              | Member X has been assigned as the moderator       |
| MemberDemoted                   | `8 user_id`              | Member X has been demoted to member               |
| UpdateChannelMemberCapabilities | `9 user_id`              | Member X has updated member permission of channel |
| InviteAccepted                  | `10 user_id`             | Member X has joined this channel                  |
| InviteRejected                  | `11 user_id`             | Member X has rejected to join this channel        |
| MemberLeave                     | `12 user_id`             | Member X has leaved this channel                  |

### Events

Events keep the client updated with changes in a channel, such as new messages, reactions, or members joining the channel.
A full list of events is shown below. The next section of the documentation explains how to listen for these events.
| Event | Trigger | Recipients
|:---|:----|:-----
| `health.check` | every 30 second to confirm that the client connection is still alive | all clients
| `message.new` | when a new message is added on a channel | clients watching the channel
| `message.read` | when a channel is marked as read | clients watching the channel
| `message.deleted` | when a message is deleted | clients watching the channel
| `message.deleted_for_me` | when a message is deleted for only current user. | only current user.
| `message.updated` | when a message is updated | clients watching the channel
| `typing.start` | when a user starts typing | clients watching the channel
| `typing.stop` | when a user stops typing | clients watching the channel
| `reaction.new` | when a message reaction is added | clients watching the channel
| `reaction.deleted` | when a message reaction is deleted | clients watching the channel
| `member.added` | when a member is added to a channel | clients watching the channel
| `member.removed` | when a member is removed from a channel | clients watching the channel
| `member.promoted` | when a member is added moderator to a channel | clients watching the channel
| `member.demoted` | when a member is removed moderator to a channel | clients watching the channel
| `member.banned` | when a member is ban to a channel | clients watching the channel
| `member.unbanned` | when a member is unban to a channel | clients watching the channel
| `channel.created` | when channel is created | clients from the user added that are not watching the channel
| `notification.invite_accepted` | when the user accepts an invite | clients from the user invited that are not watching the channel
| `notification.invite_rejected` | when the user rejects an invite | clients from the user invited that are not watching the channel
| `channel.deleted` | when a channel is deleted | clients watching the channel
| `channel.updated` | when a channel is updated | clients watching the channel


To observer events, use the delegate of `EventsController`.

```swift
let eventsController = client.eventsController()
eventsController.delegate = self
```

```swift
protocol EventsControllerDelegate: AnyObject {
    func eventsController(_ controller: EventsController, didReceiveEvent event: Event)
}
```

<br />

## Error codes

Below you can find the complete list of errors that are returned by the API together with the description, API code, and corresponding HTTP, Websocket status of each error.

#### 1. HTTP codes

| Name                      | HTTP Status Code | HTTP Status           | Ermis code | Description                                               |
| :------------------------ | :--------------- | :-------------------- | :--------- | --------------------------------------------------------- |
| InternalServerError       | 500              | Internal Server Error | 0          | Triggered when something goes wrong in our system         |
| ServiceUnavailable        | 503              | Service Unavailable   | 1          | Triggered when our system is unavailable to call          |
| Unauthorized              | 401              | Unauthorized          | 2          | Invalid JWT token                                         |
| NotFound                  | 404              | Not Found             | 3          | Resource not found                                        |
| InputError                | 400              | Bad Request           | 4          | When wrong data/parameter is sent to the API              |
| ChannelNotFound           | 400              | Bad Request           | 5          | Channel is not existed                                    |
| NoPermissionInChannel     | 400              | Bad Request           | 6          | No permission for this action in the channel              |
| NotAMemberOfChannel       | 400              | Bad Request           | 7          | Not a member of channel                                   |
| BannedFromChannel         | 400              | Bad Request           | 8          | User is banned from this channel                          |
| HaveToAcceptInviteFirst   | 400              | Bad Request           | 9          | User must accept the invite to gain permission            |
| DisabledChannelMemberCapa | 400              | Bad Request           | 10         | This action is disable for channel member role            |
| AlreadyAMemberOfChannel   | 400              | Bad Request           | 11         | User is already part of the channel and cannot join again |

#### 2. Websocket codes

| Websocket Code | Message          | Description                                   |
| :------------- | :--------------- | :-------------------------------------------- |
| 1011           | Internal Error   | Return when something goes wrong in our system     |
| 1006           | Abnormal Closure | Return when there is a connection error         |
| 1005           | Jwt Expired       | Return when the JWT has expired                    |
| 1003           | Unsupported Data | Return when the client send non-text data         |
| 1000           | Normal Closure   | Return when the client or server closes connection normally |
