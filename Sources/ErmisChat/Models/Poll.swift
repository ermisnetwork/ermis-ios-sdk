import Foundation

public struct PollVote: Codable, Equatable {
    public let userId: String
    public let text: String
    enum CodingKeys: String, CodingKey { case userId = "user_id", text }
}

/// Server-authoritative snapshot shared with the web poll contract.
public struct Poll: Codable, Equatable {
    public let choices: [String]
    public let counts: [String: Int]
    public let votes: [PollVote]
    public let multiple: Bool
    public let allowChange: Bool
    public let closed: Bool
    public var totalSelections: Int { counts.values.reduce(0, +) }
    public var totalVoters: Int { Set(votes.map(\.userId)).count }
    public func selected(by userId: String) -> Set<String> {
        Set(votes.filter { $0.userId == userId }.map(\.text))
    }
    public func canVote(userId: String) -> Bool { !closed && (allowChange || selected(by: userId).isEmpty) }
    public func percentage(_ choice: String) -> Int {
        totalSelections == 0 ? 0 : Int((Double(counts[choice, default: 0]) * 100 / Double(totalSelections)).rounded())
    }
}

public struct PollDraft {
    public var question: String
    public var choices: [String]
    public var multiple: Bool
    public var allowChange: Bool
    public init(question: String, choices: [String], multiple: Bool = false, allowChange: Bool = true) {
        self.question = question; self.choices = choices; self.multiple = multiple; self.allowChange = allowChange
    }
    public func validated() throws -> PollDraft {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw PollError.invalid("Enter a question") }
        guard question.utf16.count <= 2000 else { throw PollError.invalid("Question must be at most 2000 characters") }
        let choices = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (2...10).contains(choices.count) else { throw PollError.invalid("Enter 2–10 options") }
        let keys = choices.map { $0.precomposedStringWithCompatibilityMapping.lowercased() }
        guard Set(keys).count == choices.count else { throw PollError.invalid("Options must be different") }
        return PollDraft(question: question, choices: choices, multiple: multiple, allowChange: allowChange)
    }
}
public enum PollError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}
