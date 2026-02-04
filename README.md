
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

- iOS 14 or higher
- Swift 5.0 or higher

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
