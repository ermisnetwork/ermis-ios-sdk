import UIKit
import SwiftUI
import Combine
import ErmisChat
import ErmisSharedUI

internal enum PollStrings {
    static func text(_ en: String, _ vi: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("vi") == true ? vi : en
    }
}

/// Keyboard-aware, scrollable native poll sheet. API responses remain authoritative.
public final class PollViewController: UIViewController {
    private let model: PollViewModel
    private var subscriptions: Set<AnyCancellable> = []
    private var measuredContentHeight: CGFloat = 0
    public init(channelController: ChannelController, message: ChatMessage? = nil) {
        model = PollViewModel(controller: channelController, message: message)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = PollStrings.text(model.message == nil ? "New poll" : "Poll", model.message == nil ? "Bình chọn mới" : "Bình chọn")
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in self?.model.dismiss?() })
        navigationItem.leftBarButtonItem?.accessibilityLabel = PollStrings.text("Close", "Đóng")
        navigationController?.navigationBar.tintColor = Theme.default.colors.primary
        view.backgroundColor = .systemGroupedBackground
        navigationController?.view.backgroundColor = .systemGroupedBackground
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .systemGroupedBackground
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        if model.message == nil {
            let submit = UIBarButtonItem(title: PollStrings.text("Create", "Tạo"), primaryAction: UIAction { [weak self] _ in self?.model.create() })
            submit.style = .done;navigationItem.rightBarButtonItem = submit
            model.$busy.combineLatest(model.$question,model.$choices).receive(on: DispatchQueue.main).sink { busy,question,choices in
                submit.isEnabled = !busy && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && choices.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 2
            }.store(in: &subscriptions)
        }
        model.$busy.receive(on: DispatchQueue.main).sink { [weak self] busy in self?.navigationItem.leftBarButtonItem?.isEnabled = !busy }.store(in: &subscriptions)
        let host = UIHostingController(rootView: PollScreen(model: model, didMeasureContent: { [weak self] height in
            guard let self, abs(self.measuredContentHeight - height) > 1 else { return }
            self.measuredContentHeight = height
            if #available(iOS 16.0, *), self.model.message != nil, let sheet = self.navigationController?.sheetPresentationController {
                sheet.animateChanges { sheet.invalidateDetents() }
            }
        }))
        host.view.backgroundColor = .systemGroupedBackground
        addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        host.didMove(toParent: self)
        if let sheet = navigationController?.sheetPresentationController {
            sheet.prefersGrabberVisible = true; sheet.preferredCornerRadius = 28
            if #available(iOS 16.0, *) {
                sheet.detents = [.custom(identifier: .init("poll")) { [weak self] context in
                    guard let self, self.model.message != nil, self.measuredContentHeight > 0 else { return context.maximumDetentValue * 0.78 }
                    let header = self.navigationController?.navigationBar.bounds.height ?? 44
                    // Detent heights are within the sheet's safe area; UIKit adds the bottom inset.
                    return min(max(300, self.measuredContentHeight + header + 16), context.maximumDetentValue * 0.9)
                }, .large()]
            }
            else { sheet.detents = [.large()] }
        }
        model.dismiss = { [weak self] in self?.dismiss(animated: true) }
    }
}

private final class PollViewModel: ObservableObject {
    let controller: ChannelController
    @Published var message: ChatMessage?
    @Published var question = ""
    @Published var choices = ["", ""]
    @Published var multiple = false
    @Published var allowChange = true
    @Published var selected: Set<String> = []
    @Published var busy = false
    @Published var error: String?
    @Published var channel: Channel?
    @Published var voterUsers: [String: ChatUser] = [:]
    @Published var voterLookupFailed = false
    private var requestedVoters: Set<String> = []
    var dismiss: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    var userId: String { controller.client.currentUserId ?? "" }
    var editable: Bool { message?.poll?.canVote(userId: userId) == true && !controller.isE2eeEnabled && !busy }
    init(controller: ChannelController, message: ChatMessage?) {
        self.controller = controller; self.message = message; channel = controller.channel
        selected = message?.poll?.selected(by: controller.client.currentUserId ?? "") ?? []
        controller.messagesChangesPublisher.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let id = self.message?.id,
                let latest = self.controller.messages.first(where: { $0.id == id }) else { return }
            self.message = latest
        }.store(in: &subscriptions)
        controller.channelChangePublisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.channel = controller.channel }.store(in: &subscriptions)
        _ = controller.messages
    }
    func toggle(_ option: String) {
        guard editable, let poll = message?.poll else { return }
        if poll.multiple { if selected.contains(option) { selected.remove(option) } else { selected.insert(option) } }
        else { selected = selected.contains(option) ? [] : [option] }
    }
    func resolveVoters(_ ids: [String], retry: Bool = false) {
        if retry { requestedVoters.subtract(ids) }
        let missing = ids.filter { !requestedVoters.contains($0) }
        guard !missing.isEmpty else { return }
        requestedVoters.formUnion(missing)
        for id in missing {
            if let user = controller.client.getUser(with: id) { voterUsers[id] = user }
        }
        let remote = missing.filter { voterUsers[$0]?.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
        guard !remote.isEmpty else { return }
        voterLookupFailed = false
        // Batch the existing user-profile endpoint instead of one request per row.
        for offset in stride(from: 0, to: remote.count, by: 100) {
            controller.client.fetchUsers(with: Array(remote[offset..<min(offset + 100, remote.count)])) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let users): for user in users { self.voterUsers[user.userId] = user }
                    case .failure: self.voterLookupFailed = true
                    }
                }
            }
        }
    }
    func create() {
        guard !busy else { return }
        do {
            let draft = try PollDraft(question: question, choices: choices, multiple: multiple, allowChange: allowChange).validated()
            busy = true; error = nil; controller.createPoll(draft, completion: completed)
        } catch { self.error = error.localizedDescription }
    }
    func vote() {
        guard editable, let message else { return }
        busy = true; error = nil
        controller.votePoll(messageId: message.id, choices: message.poll?.choices.filter { selected.contains($0) } ?? [], completion: completed)
    }
    private func completed(_ result: Result<ChatMessage, Error>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.busy = false
            switch result { case .success: self.dismiss?(); case .failure(let error): self.error = error.localizedDescription }
        }
    }
}

private enum PollConfirmation: Int, Identifiable {
    case vote
    var id: Int { rawValue }
}
private struct PollKeyboardDismissal: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, *) { content.scrollDismissesKeyboard(.interactively) }
        else { content }
    }
}
private struct PollContentHeight: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private extension View {
    func measurePollHeight(_ section: String) -> some View {
        background(GeometryReader { geometry in
            SwiftUI.Color.clear.preference(key: PollContentHeight.self, value: [section: geometry.size.height])
        })
    }
}
private struct PollScreen: View {
    @ObservedObject var model: PollViewModel
    var didMeasureContent: (CGFloat) -> Void
    @State private var confirmation: PollConfirmation?
    private var accent: SwiftUI.Color { SwiftUI.Color(Theme.default.colors.primary) }
    private func t(_ en: String, _ vi: String) -> String { PollStrings.text(en, vi) }
    private func heading(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            .padding(.leading, 14).padding(.top, 18).padding(.bottom, 4)
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let message = model.message, let poll = message.poll {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "chart.bar.fill").foregroundColor(accent)
                            Text(message.text).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                        }.padding(.vertical, 12)
                        options(poll)
                    } else { draft }
                    if let error = model.error {
                        Text(error).font(.system(size: 13)).foregroundColor(.red).accessibilityIdentifier("poll_error")
                    }
                }.padding(.horizontal, 20).padding(.bottom, 12).measurePollHeight("body")
            }.modifier(PollKeyboardDismissal()).disabled(model.busy)
            if model.message != nil {
                actions.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12).measurePollHeight("footer")
            }
        }
        .background(SwiftUI.Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .onPreferenceChange(PollContentHeight.self) { sizes in didMeasureContent(sizes.values.reduce(0, +)) }
        .tint(accent)
        .interactiveDismissDisabled(model.busy)
        .alert(item: $confirmation) { kind in
            return Alert(title: Text(t("Confirm vote", "Xác nhận bình chọn")),
                message: Text(t("You cannot change your vote after submitting.", "Bạn không thể đổi phiếu sau khi gửi.")),
                primaryButton: .default(Text(t("Vote", "Bình chọn")), action: model.vote), secondaryButton: .cancel(Text(t("Cancel", "Hủy"))))
        }
    }

    private var draft: some View {
        Group {
            heading(t("Question", "Câu hỏi"))
            TextEditor(text: $model.question).font(.system(size: 16)).frame(minHeight: 88)
                .padding(10).background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment: .topLeading) {
                    if model.question.isEmpty { Text(t("Ask a question…", "Nhập câu hỏi…")).foregroundColor(.secondary).padding(.horizontal, 15).padding(.vertical, 18).allowsHitTesting(false) }
                }.accessibilityIdentifier("poll_question")
            Text("\(model.question.utf16.count)/2000").font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            heading(t("Answers", "Trả lời"))
            VStack(spacing: 0) {
                ForEach(model.choices.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 18)
                        TextField(t("Option", "Lựa chọn") + " \(index + 1)", text: $model.choices[index])
                             .font(.system(size: 16)).accessibilityIdentifier("poll_option_\(index + 1)")
                            .submitLabel(.done).onSubmit {
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                        if model.choices.count > 2 {
                            Button { model.choices.remove(at: index) } label: { Image(systemName: "minus.circle.fill").foregroundColor(.red) }
                                .buttonStyle(.plain).accessibilityLabel(t("Remove option", "Xóa lựa chọn"))
                        }
                    }.padding(.horizontal, 16).frame(minHeight: 52)
                    Divider().padding(.leading, 46)
                }
                if model.choices.count < 10 {
                    Button { model.choices.append("") } label: {
                        HStack(spacing: 12) { Image(systemName: "plus").frame(width: 18); Text(t("Add option", "Thêm lựa chọn")); Spacer() }
                            .font(.system(size: 16)).padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundColor(accent)
                }
            }.background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 20))
            Text(t("Up to 10 options", "Tối đa 10 lựa chọn")).font(.system(size: 12)).foregroundColor(.secondary).padding(.leading, 14)
            heading(t("Settings", "Cài đặt"))
            VStack(spacing: 0) {
                setting("checkmark.square.fill", color: .orange, title: t("Allow multiple choices", "Cho phép chọn nhiều đáp án"), subtitle: t("Choose more than one answer", "Có thể chọn nhiều hơn một đáp án"), value: $model.multiple)
                Divider().padding(.leading, 58)
                setting("arrow.triangle.2.circlepath", color: accent, title: t("Allow changing votes", "Cho phép thay đổi bình chọn"), subtitle: t("Update or remove your vote", "Có thể đổi hoặc hủy phiếu đã gửi"), value: $model.allowChange)
            }.background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
    private func setting(_ icon: String, color: SwiftUI.Color, title: String, subtitle: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundColor(.white).frame(width: 30, height: 30).background(color).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 14)); Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary) }
                Spacer(minLength: 0)
            }.contentShape(Rectangle()).onTapGesture { value.wrappedValue.toggle() }
            Toggle(title, isOn: value).labelsHidden().tint(accent).accessibilityLabel(title)
        }.padding(14)
    }

    private func options(_ poll: Poll) -> some View {
        Group {
            Text(poll.closed ? t("Closed", "Đã đóng") : poll.multiple ? t("Select one or more options", "Chọn một hoặc nhiều đáp án") : t("Select one option", "Chọn một đáp án"))
                .font(.system(size: 13)).foregroundColor(.secondary).padding(.bottom, 6)
            ForEach(poll.choices, id: \.self) { choice in
                VStack(spacing: 4) {
                    Button { model.toggle(choice) } label: {
                        VStack(spacing: 9) {
                            HStack(spacing: 10) {
                                Image(systemName: model.selected.contains(choice) ? "checkmark.circle.fill" : "circle").foregroundColor(model.selected.contains(choice) ? accent : .secondary)
                                Text(choice).foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(poll.percentage(choice))%").font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(SwiftUI.Color.primary.opacity(0.04))
                                    Capsule().fill(accent.opacity(0.28)).frame(width: geometry.size.width * CGFloat(poll.percentage(choice)) / 100)
                                }
                            }.frame(height: 3)
                        }.font(.system(size: 15)).padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 54).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("poll_vote_option_" + choice).disabled(!model.editable)
                        .background(SwiftUI.Color(UIColor.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.selected.contains(choice) ? accent.opacity(0.6) : SwiftUI.Color(UIColor.separator).opacity(0.3), lineWidth: 1))
                    voterAvatars(choice, poll)
                }
            }
            Label("\(poll.totalVoters) " + t("voters", "người bình chọn"), systemImage: "person.2").font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 6)
        }
    }
    private func voterAvatars(_ option: String, _ poll: Poll) -> some View {
        let ids = Set(poll.votes.filter { $0.text == option }.map(\.userId)).sorted()
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            if !ids.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(ids, id: \.self) { id in
                            let member = model.voterUsers[id] ?? model.channel?.lastActiveMembers.first { $0.userId == id }
                            let name = member?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                            AsyncImage(url: member?.imageURL) { image in image.resizable().scaledToFill() }
                                placeholder: { Text(String((name?.isEmpty == false ? name! : "?").prefix(1))).font(.system(size: 13, weight: .semibold)).foregroundColor(accent).frame(maxWidth: .infinity, maxHeight: .infinity).background(accent.opacity(0.12)) }
                                .frame(width: 28, height: 28).clipShape(Circle()).frame(width: 44, height: 44)
                                .overlay(PollVoterPopupAnchor(model: model, userId: id, option: option))
                        }
                    }
                }.frame(width: CGFloat(min(ids.count, 5)) * 44, height: 44)
            }
        }.padding(.horizontal, 6)
            .onAppear { model.resolveVoters(ids) }.onChange(of: ids) { model.resolveVoters($0) }
    }
    private var actions: some View {
        VStack(spacing: 4) {
            if model.busy { ProgressView() }
            if let poll = model.message?.poll {
                if model.editable {
                    let unchanged = model.selected == poll.selected(by: model.userId)
                    Button(model.selected.isEmpty && !poll.selected(by: model.userId).isEmpty ? t("Remove vote", "Hủy bình chọn") : t("Confirm vote", "Xác nhận")) {
                        if !poll.allowChange { confirmation = .vote } else { model.vote() }
                    }.font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundColor(unchanged ? SwiftUI.Color(UIColor.secondaryLabel) : .white)
                        .background(unchanged ? SwiftUI.Color(UIColor.tertiarySystemFill) : accent).clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(unchanged).accessibilityIdentifier("poll_confirm")
                }
            }
        }
    }
}

/// Option-specific voter list shared by message previews and the results sheet.
private final class PollVoterListViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    let client: ErmisClient
    let ids: [String]
    let option: String
    var users: [String: ChatUser]
    private let rows = UIStackView()
    init(client: ErmisClient, option: String, ids: [String], users: [String: ChatUser]) {
        self.client=client;self.option=option;self.ids=ids;self.users=users
        super.init(nibName:nil,bundle:nil)
        modalPresentationStyle = .popover
        preferredContentSize=CGSize(width:280,height:min(320, CGFloat(ids.count)*48+52))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .secondarySystemGroupedBackground
        view.accessibilityIdentifier="poll_voters_list"
        let title=UILabel();title.text="\(option) · \(ids.count) " + PollStrings.text("votes","phiếu");title.font = .systemFont(ofSize:13,weight:.semibold);title.numberOfLines=2
        title.accessibilityIdentifier="poll_voters_title"
        let scroll=UIScrollView();rows.axis = .vertical;rows.spacing=0
        view.addSubview(title);view.addSubview(scroll);scroll.addSubview(rows)
        [title,scroll,rows].forEach { $0.translatesAutoresizingMaskIntoConstraints=false }
        NSLayoutConstraint.activate([title.topAnchor.constraint(equalTo:view.topAnchor,constant:12),title.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),title.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-14),scroll.topAnchor.constraint(equalTo:title.bottomAnchor,constant:8),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-14),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-10),rows.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor),rows.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor),rows.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor),rows.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor),rows.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor)])
        for id in ids { if let user=client.getUser(with:id) { users[id]=user } }
        render();resolve()
    }
    private func render() {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0);$0.removeFromSuperview() }
        for id in ids {
            let user=users[id];let avatar=UserAvatarView();avatar.content = .init(imageURL:user?.imageURL,placeholderString:user?.name ?? "?",isOnline:false)
            avatar.widthAnchor.constraint(equalToConstant:30).isActive=true;avatar.heightAnchor.constraint(equalToConstant:30).isActive=true
            let name=UILabel();name.text=user?.name?.isEmpty==false ? user?.name : PollStrings.text("Loading name…","Đang tải tên…");name.font = .systemFont(ofSize:13);name.numberOfLines=2
            let text=UIStackView(arrangedSubviews:[name]);text.axis = .vertical;text.spacing=2
            if id==client.currentUserId { let you=UILabel();you.text=PollStrings.text("You","Bạn");you.font = .systemFont(ofSize:10);you.textColor = .secondaryLabel;text.addArrangedSubview(you) }
            let row=UIStackView(arrangedSubviews:[avatar,text]);row.spacing=10;row.alignment = .center;row.heightAnchor.constraint(greaterThanOrEqualToConstant:48).isActive=true
            rows.addArrangedSubview(row)
        }
    }
    private func resolve() {
        let missing=ids.filter { users[$0]?.name?.isEmpty != false }
        for start in stride(from:0,to:missing.count,by:100) {
            client.fetchUsers(with:Array(missing[start..<min(start+100,missing.count)])) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let users): for user in users { self.users[user.userId]=user };self.render()
                    case .failure:
                        let retry=UIButton(type:.system);retry.setTitle(PollStrings.text("Retry","Thử lại"),for:.normal)
                        retry.addAction(UIAction { [weak self,weak retry] _ in retry?.removeFromSuperview();self?.resolve() },for:.touchUpInside);self.rows.addArrangedSubview(retry)
                    }
                }
            }
        }
    }
    func show(from button: UIView) {
        var responder:UIResponder?=button
        while responder != nil && !(responder is UIViewController) { responder=responder?.next }
        guard let owner=responder as? UIViewController,owner.presentedViewController==nil else { return }
        popoverPresentationController?.sourceView=button;popoverPresentationController?.sourceRect=button.bounds
        popoverPresentationController?.permittedArrowDirections=[.up,.down];popoverPresentationController?.delegate=self
        owner.present(self,animated:true)
    }
    func adaptivePresentationStyle(for controller:UIPresentationController,traitCollection:UITraitCollection)->UIModalPresentationStyle { .none }
}
private struct PollVoterPopupAnchor: UIViewRepresentable {
    let model: PollViewModel
    let userId: String
    let option: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.show(_:)), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.model = model; context.coordinator.userId = userId; context.coordinator.option = option
        button.accessibilityIdentifier = "poll_voter_avatar_" + option + "_" + userId
        let name = model.voterUsers[userId]?.name
        button.accessibilityLabel = name?.isEmpty == false ? name : PollStrings.text("Voter", "Người bình chọn")
        button.accessibilityHint = PollStrings.text("Show name", "Hiển thị tên")
    }
    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var model: PollViewModel?
        var userId = ""
        var option = ""
        @objc func show(_ button: UIButton) {
            guard let model else { return }
            let ids=Set(model.message?.poll?.votes.filter { $0.text==option }.map(\.userId) ?? []).sorted()
            PollVoterListViewController(client:model.controller.client,option:option,ids:ids,users:model.voterUsers).show(from:button)
        }
        func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    }
}

internal final class PollCardView: UIStackView {
    private var renderedPoll: Poll?
    private var renderedQuestion: String?
    private var renderedUserId: String?
    private var renderedCanClose: Bool?
    private var renderGeneration=0
    private var openAction: (() -> Void)?
    private var closeAction: ((UIButton) -> Void)?
    private var accent: UIColor { Theme.default.colors.primary }
    init() {
        super.init(frame: .zero); axis = .vertical; spacing = 6; isLayoutMarginsRelativeArrangement = true
        layoutMargins = .init(top: 10, left: 12, bottom: 0, right: 12)
        backgroundColor = .secondarySystemGroupedBackground; layer.cornerRadius = 16; layer.borderWidth = 1
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor }
    func configure(message: ChatMessage, channel: Channel?, currentUserId: String?, client: ErmisClient?, action: @escaping () -> Void, closeAction: @escaping (UIButton) -> Void) {
        openAction = action; self.closeAction = closeAction
        guard let poll = message.poll else { return }
        let uid = currentUserId ?? (message.isSentByCurrentUser ? message.author.userId : "")
        let canClose = !poll.closed && channel?.isE2eeEnabled == false && (message.isSentByCurrentUser || message.author.userId == uid || channel?.membership?.isModerator == true)
        accessibilityIdentifier = "poll_card_" + message.text
        if poll == renderedPoll && message.text == renderedQuestion && uid == renderedUserId && canClose == renderedCanClose { return }
        renderGeneration += 1
        let generation=renderGeneration
        renderedPoll = poll; renderedQuestion = message.text; renderedUserId = uid;renderedCanClose = canClose
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        func label(_ text: String, size: CGFloat, bold: Bool = false) -> UILabel {
            let label = UILabel(); label.text = text; label.numberOfLines = 0
            label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular); label.textColor = .label; return label
        }
        func button(_ title: String, primary: Bool = false, closing: Bool = false) -> UIButton {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = (closing ? "poll_close_" : "poll_open_") + message.text
            button.titleLabel?.font = .systemFont(ofSize: primary ? 14 : 11, weight: primary ? .semibold : .regular)
            button.setTitleColor(primary ? .white : accent, for: .normal)
            if primary { button.backgroundColor = accent; button.layer.cornerRadius = 12 }
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { [weak self, weak button] _ in
                if closing { if let button { self?.closeAction?(button) } } else { self?.openAction?() }
            }, for: .touchUpInside); return button
        }
        let icon = UIImageView(image: UIImage(systemName: "chart.bar.fill")); icon.tintColor = accent; icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let question = label(message.text, size: 15, bold: true); question.numberOfLines = 6
        let header = UIStackView(arrangedSubviews: [icon, question]); header.spacing = 8; header.alignment = .top
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        if poll.closed {
            let badge=UIButton(type:.custom)
            var configuration=UIButton.Configuration.plain()
            configuration.title=PollStrings.text("Closed","Đã đóng")
            configuration.image=UIImage(systemName:"lock.fill",withConfiguration:UIImage.SymbolConfiguration(pointSize:10,weight:.semibold))
            configuration.imagePadding=4;configuration.contentInsets = .init(top:3,leading:8,bottom:3,trailing:8)
            configuration.baseForegroundColor = .secondaryLabel
            configuration.background.backgroundColor = .tertiarySystemFill
            configuration.background.cornerRadius=12
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var value=attributes;value.font = .systemFont(ofSize:11,weight:.semibold);return value
            }
            badge.configuration=configuration;badge.isUserInteractionEnabled=false;badge.accessibilityTraits = .staticText
            badge.accessibilityIdentifier="poll_closed_badge_"+message.text
            badge.setContentHuggingPriority(.required,for:.horizontal);badge.setContentCompressionResistancePriority(.required,for:.horizontal)
            header.addArrangedSubview(badge)
        }
        addArrangedSubview(header); setCustomSpacing(8, after: header)
        var previewRows:[String:PollPreviewOptionView]=[:]
        for choice in poll.choices.prefix(3) {
            let row = PollPreviewOptionView(choice: choice, percentage: poll.percentage(choice), selected: poll.selected(by: uid).contains(choice), blue: accent)
            row.accessibilityIdentifier = "poll_preview_" + choice
            row.accessibilityTraits = .staticText
            previewRows[choice]=row
            addArrangedSubview(row)
        }
        if let client {
            let shownIds=Set(previewRows.keys.flatMap { option in Array(Set(poll.votes.filter { $0.text==option }.map(\.userId)).sorted().prefix(2)) })
            var users:[String:ChatUser]=[:]
            for id in shownIds { users[id]=client.getUser(with:id) ?? channel?.lastActiveMembers.first { $0.userId==id } }
            func renderVoters(_ profiles:[String:ChatUser]) {
                for (choice,row) in previewRows {
                    let ids=Set(poll.votes.filter { $0.text==choice }.map(\.userId)).sorted()
                    row.setVoters(ids:ids,users:profiles) { anchor in
                        PollVoterListViewController(client:client,option:choice,ids:ids,users:profiles).show(from:anchor)
                    }
                }
            }
            renderVoters(users)
            let missing=shownIds.filter { users[$0]?.name?.isEmpty != false }
            if !missing.isEmpty {
                client.fetchUsers(with:Array(missing)) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self,self.renderGeneration==generation else { return }
                        if case .success(let fetched)=result { for user in fetched { users[user.userId]=user };renderVoters(users) }
                    }
                }
            }
        }
        if poll.choices.count > 3 { addArrangedSubview(label("+ \(poll.choices.count - 3) " + PollStrings.text("options", "lựa chọn"), size: 11)) }
        if !poll.closed && poll.canVote(userId: uid) {
            addArrangedSubview(button(poll.selected(by: uid).isEmpty ? PollStrings.text("Vote", "Bình chọn") : PollStrings.text("Change vote", "Đổi bình chọn"), primary: true))
        }
        if poll.closed || !poll.canVote(userId: uid) { addArrangedSubview(button(PollStrings.text("Results", "Kết quả"), primary: true)) }
        let divider = UIView(); divider.backgroundColor = .separator; divider.alpha = 0.35; divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true; addArrangedSubview(divider)
        let count = label("\(poll.totalVoters) " + PollStrings.text("voters", "người bình chọn"), size: 11); count.textColor = .secondaryLabel
        let footer = UIStackView(arrangedSubviews: [count]); footer.alignment = .center; footer.spacing = 12
        if canClose {
            let close = button(PollStrings.text("Close poll", "Đóng bình chọn"), closing: true)
            close.setTitleColor(.systemRed, for: .normal);close.setContentHuggingPriority(.required, for: .horizontal)
            footer.addArrangedSubview(close)
        } else { footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true }
        addArrangedSubview(footer);setCustomSpacing(0, after: divider)
    }
}

private final class PollPreviewOptionView: UIView {
    private let fill = UIView()
    private let content=UIStackView()
    private let answerRow=UIStackView()
    private var voters:UIStackView?
    private let percentage: Int
    private let hasSelection: Bool
    private let blue: UIColor
    init(choice: String, percentage: Int, selected: Bool, blue: UIColor) {
        self.percentage = percentage; self.hasSelection = selected; self.blue = blue
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemGroupedBackground; layer.cornerRadius = 12; layer.borderWidth = 1; clipsToBounds = true
        fill.backgroundColor = (selected ? blue : UIColor.secondaryLabel).withAlphaComponent(0.10)
        fill.isUserInteractionEnabled = false; addSubview(fill)
        let text = UILabel(); text.text = (selected ? "✓  " : "") + choice; text.font = .systemFont(ofSize: 13, weight: .medium); text.numberOfLines = 3; text.textColor = .label
        let value = UILabel(); value.text = "\(percentage)%"; value.font = .systemFont(ofSize: 12, weight: .medium); value.textColor = selected ? blue : .secondaryLabel
        value.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row=answerRow;row.addArrangedSubview(text);row.addArrangedSubview(value);row.alignment = .center;row.spacing=6
        content.axis = .vertical;content.spacing=4;content.addArrangedSubview(row)
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        NSLayoutConstraint.activate([heightAnchor.constraint(greaterThanOrEqualToConstant: 44), content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), content.topAnchor.constraint(equalTo: topAnchor, constant: 10), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)])
        row.isAccessibilityElement = false
    }
    func setVoters(ids:[String],users:[String:ChatUser],show:@escaping(UIView)->Void) {
        if let voters { answerRow.removeArrangedSubview(voters);voters.removeFromSuperview() };voters=nil
        guard !ids.isEmpty else { return }
        let strip=UIStackView();strip.alignment = .center;strip.spacing=2
        for id in ids.prefix(2) {
            let user=users[id];let button=UIButton(type:.custom)
            button.accessibilityIdentifier="poll_preview_voter_"+id;button.accessibilityLabel=PollStrings.text("Show voters","Xem người bình chọn")
            let avatar=UserAvatarView();avatar.content = .init(imageURL:user?.imageURL,placeholderString:user?.name ?? "?",isOnline:false)
            avatar.isUserInteractionEnabled=false;avatar.translatesAutoresizingMaskIntoConstraints=false;button.addSubview(avatar)
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant:24),button.heightAnchor.constraint(equalToConstant:28),avatar.widthAnchor.constraint(equalToConstant:20),avatar.heightAnchor.constraint(equalToConstant:20),avatar.centerXAnchor.constraint(equalTo:button.centerXAnchor),avatar.centerYAnchor.constraint(equalTo:button.centerYAnchor)])
            button.addAction(UIAction { [weak button] _ in if let button { show(button) } },for:.touchUpInside);strip.addArrangedSubview(button)
        }
        if ids.count>2 {
            let more=UIButton(type:.system);more.setTitle("+\(ids.count-2)",for:.normal);more.titleLabel?.font = .systemFont(ofSize:10,weight:.medium);more.backgroundColor = .tertiarySystemFill;more.layer.cornerRadius=14
            more.accessibilityIdentifier="poll_preview_more_voters";more.accessibilityLabel=PollStrings.text("All voters","Tất cả người bình chọn")
            more.widthAnchor.constraint(equalToConstant:28).isActive=true;more.heightAnchor.constraint(equalToConstant:28).isActive=true
            more.addAction(UIAction { [weak more] _ in if let more { show(more) } },for:.touchUpInside);strip.addArrangedSubview(more)
        }
        strip.setContentHuggingPriority(.required,for:.horizontal);strip.setContentCompressionResistancePriority(.required,for:.horizontal)
        voters=strip;answerRow.insertArrangedSubview(strip,at:answerRow.arrangedSubviews.count-1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(percentage) / 100, height: bounds.height)
        layer.borderColor = (hasSelection ? blue : UIColor.separator.withAlphaComponent(0.35)).cgColor
    }
}
