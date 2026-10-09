import CoreData
import XCTest
@testable import ErmisChat

final class PollContractTests: XCTestCase {
    private let json = """
    {"id":"poll-fixture","cid":"messaging:project:room","type":"poll","text":"Lunch?",
    "user":{"id":"author","project_id":"project"},"created_at":"2026-10-08T00:00:00Z","poll_type":"multiple",
    "poll_choice_counts":{"Rice":2,"Soup":1},"allow_change_choice":true,"poll_closed":false,
    "latest_poll_choices":[{"user_id":"alice","text":"Rice"},{"user_id":"alice","text":"Soup"},{"user_id":"bob","text":"Rice"}]}
    """
    private func payload() throws -> MessagePayload { try JSONDecoder.default.decode(MessagePayload.self, from: Data(json.utf8)) }
    func testValidationUsesWebUnicodeAndLengthRules() throws {
        XCTAssertEqual(try PollDraft(question: " Q ", choices: [" A ","","B"]).validated().choices, ["A","B"])
        for draft in [PollDraft(question: " ",choices: ["A","B"]), PollDraft(question: String(repeating:"x",count:2001),choices:["A","B"]),
            PollDraft(question:"Q",choices:["Ａ","a"]),PollDraft(question:"Q",choices:["A"]),PollDraft(question:"Q",choices:(0...10).map(String.init))] {
            XCTAssertThrowsError(try draft.validated())
        }
        XCTAssertEqual(try PollDraft(question:"Q",choices:(0...9).map(String.init)).validated().choices.count,10)
    }
    func testDecodesWebPollAndCountsDistinctVoters() throws {
        let message = try payload(); XCTAssertEqual(message.type,.poll)
        let poll = try XCTUnwrap(message.poll)
        XCTAssertEqual(poll.totalVoters,2); XCTAssertEqual(poll.totalSelections,3)
        XCTAssertEqual(poll.percentage("Rice"),67); XCTAssertEqual(poll.percentage("Soup"),33)
        XCTAssertEqual(poll.selected(by:"alice"),["Rice","Soup"])
    }
    func testImmutableClosedAndEmptyResults() {
        let poll = Poll(choices:["A","B"],counts:[:],votes:[PollVote(userId:"me",text:"A")],multiple:false,allowChange:false,closed:false)
        XCTAssertFalse(poll.canVote(userId:"me")); XCTAssertTrue(poll.canVote(userId:"peer")); XCTAssertEqual(poll.percentage("A"),0)
        XCTAssertFalse(Poll(choices:poll.choices,counts:[:],votes:[],multiple:false,allowChange:true,closed:true).canVote(userId:"me"))
    }
    func testPollEventAliasesDecodeAsMessageUpdates() throws {
        for type in ["pollchoice.new","pollchoice.delete","pollchoices.updated"] {
            let eventJSON = """
            {"type":"\(type)","cid":"messaging:project:room","created_at":"2026-10-08T00:00:00Z","user":{"id":"alice","project_id":"project"},"message":\(json)}
            """
            let event = try JSONDecoder.default.decode(EventPayload.self,from:Data(eventJSON.utf8))
            XCTAssertTrue(try event.eventType.event(from:event) is MessageUpdatedEventDTO)
        }
    }
    func testAllBackendSystemCodesDecodeIncludingPollCreatedAndClosed() {
        for code in 1...23 {
            let param = code == 14 ? "true" : code == 15 ? "60000" : "Lunch with friends"
            let event = SystemMessage(systemMessage: "\(code) fixture-author \(param)")
            if case .unknown = event { XCTFail("Unhandled backend code \(code)") }
        }
        if case let .pollClosed(userId,question) = SystemMessage(systemMessage:"23 fixture-author Lunch with friends") {
            XCTAssertEqual(userId,"fixture-author");XCTAssertEqual(question,"Lunch with friends")
        } else { XCTFail("Poll-close system message lost") }
    }
    func testPersistsPollAndIncludesItInChannelFetch() throws {
        let database = DatabaseContainer(kind:.inMemory,shouldResetEphemeralValuesOnStart:false)
        let loaded = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !database.persistentStoreCoordinator.persistentStores.isEmpty },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[loaded],timeout:5),.completed)
        let cid = try ChannelId(cid:"messaging:project:room")
        let channelJSON = """
        {"channel":{"cid":"messaging:project:room","type":"messaging","save_message":true,"mls_enabled":false,"member_count":2,"created_at":"2026-10-08T00:00:00Z","updated_at":"2026-10-08T00:00:00Z"},"messages":[\(json)],"read":[]}
        """
        let channel = try JSONDecoder.default.decode(ChannelPayload.self,from:Data(channelJSON.utf8))
        try database.writeAndWait { session in
            _ = try session.saveChannel(payload:channel)
        }
        database.viewContext.performAndWait {
            let dto = MessageDTO.load(id:"poll-fixture",context:database.viewContext)
            XCTAssertNotNil(dto?.pollData)
            XCTAssertEqual(try? dto?.asModel().poll?.totalVoters,2)
            let request = MessageDTO.messagesFetchRequest(for:cid, pageSize:20, deletedMessagesVisibility:.alwaysHidden, shouldShowShadowedMessages:false)
            XCTAssertEqual(try? database.viewContext.fetch(request).filter { $0.type == "poll" }.count,1)
        }
    }
}
