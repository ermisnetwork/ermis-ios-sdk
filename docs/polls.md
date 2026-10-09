# Polls

Polls use the same server contract as Uhm web. Secure/E2EE channels are rejected before plaintext requests, including inherited MLS state for topics. Server authorization and returned snapshots are authoritative.

## iOS

`ChannelController.createPoll(PollDraft(question:choices:multiple:allowChange:), completion:)` validates a trimmed question up to 2000 UTF-16 code units and 2–10 nonempty distinct options (NFKC + lowercase). `votePoll(messageId:choices:completion:)` atomically replaces the user's entire selection; `[]` removes their vote. `closePoll(messageId:completion:)` permanently closes a poll; the server permits its author or channel owner/moderator.

`ChatMessage.poll` exposes choices, counts, votes, multiple, allowChange and closed. `selected(by:)`, `totalVoters`, `totalSelections`, `percentage(_:)`, `canVote(userId:)` provide the corresponding projections. Percentages use total selections, while participant counts deduplicate user IDs. Existing non-poll messages have nil poll.

The default composer and message content view provide native creation/results/voter sheets and cards. Actions retain drafts on failure and prevent duplicate submissions. Poll choice events reuse the message-update path. Core Data model 6 adds optional binary JSON `pollData`; models 1–5 remain available for automatic inferred migration. Removing a newer binary does not make a version-6 store readable by an older model.

## Android

`ChannelClient.createPoll(PollDraft(...))`, `votePoll(message, choices)` and `closePoll(message)` return standard SDK calls. `ErmisClient` also exposes these operations. The channel must be loaded in the repository; topic parent state must establish that it is not encrypted. Poll metadata uses existing message extraData flattening/cache storage and the `Message.poll` extension. Native components expose `PollDialogs.create(context, channel)` and `details(context, message)`. `MessageComposerView.pollButtonClickListener` is bound by the Uhm host to its current channel; custom hosts should bind this callback too. Leading content also exposes the callback for custom menus.

## Wire contract

- Create: `POST /channels/{type}/{id}/message`, `message` containing `id`, `text`, `poll_type` (`single`/`multiple`), `poll_choices`, `allow_change_choice`.
- Replace/remove: `POST /messages/{type}/{id}/{messageId}/poll`, `{"choices":[...]}`.
- Close: `POST /messages/{type}/{id}/{messageId}/poll/close`, `{}`.
- Snapshots: `poll_type`, `poll_choices` when present, `poll_choice_counts`, `latest_poll_choices` with `user_id`/`text`, `allow_change_choice`, `poll_closed`.
- Realtime: `pollchoice.new`, `pollchoice.delete`, `pollchoices.updated`, `message.updated`. These update the existing poll message and do not increase unread/message counts as a new chat message.

Implementation history and acceptance evidence: [canonical mobile plan](../../ermis-chat-ios/docs/todo/mobile_poll_plan.md).

## System messages

Both native clients handle all current backend system codes 1–23 in chat and channel previews. Poll-created `22 <user-id> <question>` and poll-closed `23 <user-id> <question>` resolve names and render localized Vietnamese/English text. Android also supports owner transfer (18) and friend-invite rejection (21). Unknown future formats remain visible as raw text; missing users fall back to their ID as on web. The implementation journal records the inventory and executable evidence.

## Voter profiles and confirmation state

Both native results sheets show right-aligned voter avatars beneath each answer; tapping an avatar opens a compact scrollable list of all users who voted for that answer, with avatars and resolved display names. A horizontally scrollable strip retains access to every voter; the total participant count appears once below the answers. Profiles resolve when results appear from cached users and missing profiles through the existing users-by-ID endpoint in batches of up to 100. The limited channel-member snapshot is a fallback, not the sole source. Failed profile requests offer retry; voter lists do not use raw identifiers as display names. Android confirmation is disabled with neutral disabled colors until the selection changes. An empty replacement remains available as Remove vote when the current user already has a changeable vote.

Native card actions are explicit: Vote/Change vote or Results opens the details sheet; Close poll opens a separate confirmation directly from the card. Preview answers and participant counts are informational. The results sheet contains selection confirmation only. The default mobile card exposes Close on open polls for their author or a channel owner/moderator. iOS resolves author ownership from the actual client identity and the existing message ownership flag, independently of the channel membership snapshot. Closed polls omit Close. Android uses a compact confirmation with in-flight disabling and retained error/retry, iOS uses its native alert.

Message previews keep answer text, up to two small voter avatars plus a +N overflow icon, and percentage on one row. Tapping any preview avatar/overflow opens the same option-specific voter list, including voters omitted from the preview. Only visible preview profiles are resolved at bind; remaining profiles resolve when the list opens. Android poll avatars use a scoped borderless circular style. Closed cards show a small neutral gray pill with a lock icon matching web.

Default native contextual/long-press menus include Close poll for an open, unencrypted poll authored by the current client user or authorized through channel owner/moderator membership. Both the iOS SDK menu and Uhm's menu override use the same capability/action; Android rechecks channel and permission in its message-options handler. This action opens the existing close confirmation directly, never the voting sheet. Closed and unauthorized polls omit the menu item.
