import Foundation

private struct CreatePollBody: Encodable {
    let message: Draft
    struct Draft: Encodable {
        let id: String
        let text: String
        let poll_type: String
        let poll_choices: [String]
        let allow_change_choice: Bool
    }
}

extension ChannelController {
    public func createPoll(_ draft: PollDraft, completion: @escaping (Result<ChatMessage, Error>) -> Void) {
        do {
            let draft = try draft.validated()
            guard let cid, isChannelAlreadyCreated, channel != nil else { throw PollError.invalid("Open the channel before creating a poll") }
            guard !isE2eeEnabled else { throw PollError.invalid("Polls are not supported in secure chats yet") }
            let body = CreatePollBody(message: .init(id: UUID().uuidString, text: draft.question,
                poll_type: draft.multiple ? "multiple" : "single", poll_choices: draft.choices,
                allow_change_choice: draft.allowChange))
            let endpoint = Endpoint<MessagePayload.Boxed>(path: .sendMessage(cid), method: .post, body: body)
            performPoll(endpoint, cid: cid, completion: completion)
        } catch { callback { completion(.failure(error)) } }
    }

    /// `choices` replaces the entire current selection. An empty array removes the vote.
    public func votePoll(messageId: MessageId, choices: [String], completion: @escaping (Result<ChatMessage, Error>) -> Void) {
        guard let cid, channel != nil, !isE2eeEnabled else {
            callback { completion(.failure(PollError.invalid("Polls are not supported in secure or unavailable chats"))) }; return
        }
        let endpoint = Endpoint<MessagePayload.Boxed>(path: .pollVote(messageId, cid), method: .post, body: ["choices": choices])
        performPoll(endpoint, cid: cid, completion: completion)
    }

    public func closePoll(messageId: MessageId, completion: @escaping (Result<ChatMessage, Error>) -> Void) {
        guard let cid, channel != nil, !isE2eeEnabled else {
            callback { completion(.failure(PollError.invalid("Polls are not supported in secure or unavailable chats"))) }; return
        }
        let endpoint = Endpoint<MessagePayload.Boxed>(path: .pollClose(messageId, cid), method: .post, body: [String: String]())
        performPoll(endpoint, cid: cid, completion: completion)
    }

    private func performPoll(_ endpoint: Endpoint<MessagePayload.Boxed>, cid: ChannelId,
        completion: @escaping (Result<ChatMessage, Error>) -> Void) {
        client.apiClient.request(endpoint: endpoint) { [self] result in
            switch result {
            case .failure(let error): callback { completion(.failure(error)) }
            case .success(let boxed):
                client.databaseContainer.write { session in
                    _ = try session.saveMessage(payload: boxed.message, for: cid, syncOwnReactions: false, cache: nil)
                } completion: { error in
                    if let error { self.callback { completion(.failure(error)) }; return }
                    self.client.databaseContainer.viewContext.perform {
                        let result = Result {
                            guard let dto = MessageDTO.load(id: boxed.message.id,
                                context: self.client.databaseContainer.viewContext) else {
                                throw PollError.invalid("Poll response is no longer available locally")
                            }
                            return try dto.asModel()
                        }
                        self.callback { completion(result) }
                    }
                }
            }
        }
    }
}
