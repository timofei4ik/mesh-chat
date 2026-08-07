import UIKit

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let chat: ChatPreview
    private var messages = DemoData.messages
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let inputField = UITextField()
    private let monitor = FPSMonitor()
    private let fpsLabel = UILabel()
    private var composerBottom: NSLayoutConstraint!

    init(chat: ChatPreview) {
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeshTheme.background
        buildHeader()
        buildConversation()
        buildComposer()

        monitor.onUpdate = { [weak self] fps in self?.fpsLabel.text = "\(fps) FPS" }
        monitor.start()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToBottom(animated: false)
    }

    private func buildHeader() {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let back = UIButton(type: .system)
        back.translatesAutoresizingMaskIntoConstraints = false
        MeshTheme.setIcon(on: back, name: "chevron.left", fallback: "<")
        back.tintColor = MeshTheme.primaryText
        back.backgroundColor = MeshTheme.surface
        back.layer.cornerRadius = 22
        back.addTarget(self, action: #selector(goBack), for: .touchUpInside)

        let identity = UIButton(type: .system)
        identity.translatesAutoresizingMaskIntoConstraints = false
        identity.backgroundColor = MeshTheme.surface
        identity.layer.cornerRadius = 18
        identity.setTitle("\(chat.name)\n  online", for: .normal)
        identity.titleLabel?.numberOfLines = 2
        identity.titleLabel?.textAlignment = .center
        identity.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        identity.setTitleColor(MeshTheme.primaryText, for: .normal)
        identity.addTarget(self, action: #selector(openProfile), for: .touchUpInside)

        let avatar = InitialAvatarView(text: chat.name, color: chat.color, size: 44)
        let avatarButton = UIButton(type: .custom)
        avatarButton.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatar)
        avatar.pinEdges(to: avatarButton)
        avatarButton.addTarget(self, action: #selector(openProfile), for: .touchUpInside)

        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsLabel.textColor = MeshTheme.secondaryText
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)

        [back, identity, avatarButton, fpsLabel].forEach(header.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 56),
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),
            identity.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            identity.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            identity.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            identity.heightAnchor.constraint(equalToConstant: 44),
            avatarButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            avatarButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            avatarButton.widthAnchor.constraint(equalToConstant: 44),
            avatarButton.heightAnchor.constraint(equalToConstant: 44),
            fpsLabel.trailingAnchor.constraint(equalTo: avatarButton.leadingAnchor, constant: -8),
            fpsLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func buildConversation() {
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseIdentifier)
    }

    private func buildComposer() {
        let composer = UIView()
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.backgroundColor = MeshTheme.surface
        composer.layer.cornerRadius = 24
        view.addSubview(composer)

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholder = "Message"
        inputField.attributedPlaceholder = NSAttributedString(string: "Message", attributes: [.foregroundColor: MeshTheme.secondaryText])
        inputField.textColor = MeshTheme.primaryText
        inputField.returnKeyType = .send
        inputField.delegate = self

        let attach = UIButton(type: .system)
        attach.translatesAutoresizingMaskIntoConstraints = false
        MeshTheme.setIcon(on: attach, name: "paperclip", fallback: "+")
        attach.tintColor = MeshTheme.secondaryText

        let send = UIButton(type: .system)
        send.translatesAutoresizingMaskIntoConstraints = false
        MeshTheme.setIcon(on: send, name: "arrow.up.circle.fill", fallback: "Send")
        send.tintColor = MeshTheme.cyan
        send.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)

        [attach, inputField, send].forEach(composer.addSubview)
        composerBottom = composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composerBottom,
            composer.heightAnchor.constraint(equalToConstant: 48),
            tableView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),
            attach.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 8),
            attach.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            attach.widthAnchor.constraint(equalToConstant: 34),
            attach.heightAnchor.constraint(equalToConstant: 34),
            inputField.leadingAnchor.constraint(equalTo: attach.trailingAnchor, constant: 4),
            inputField.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -4),
            inputField.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            send.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -8),
            send.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            send.widthAnchor.constraint(equalToConstant: 36),
            send.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseIdentifier, for: indexPath) as! MessageCell
        cell.configure(with: messages[indexPath.row])
        return cell
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendMessage()
        return false
    }

    @objc private func sendMessage() {
        guard let text = inputField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        messages.append(.init(text: text, time: DateFormatter.shortTime.string(from: Date()), outgoing: true))
        inputField.text = nil
        tableView.performBatchUpdates {
            tableView.insertRows(at: [IndexPath(row: messages.count - 1, section: 0)], with: .fade)
        } completion: { [weak self] _ in self?.scrollToBottom(animated: true) }
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY - view.safeAreaInsets.bottom)
        composerBottom.constant = -8 - overlap
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    private func scrollToBottom(animated: Bool) {
        guard !messages.isEmpty else { return }
        tableView.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: animated)
    }

    @objc private func goBack() { navigationController?.popViewController(animated: !MeshTheme.shouldReduceMotion) }
    @objc private func openProfile() { navigationController?.pushViewController(ProfileViewController(name: chat.name, handle: "@\(chat.name.lowercased())", color: chat.color), animated: !MeshTheme.shouldReduceMotion) }
}

private extension DateFormatter {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

final class MessageCell: UITableViewCell {
    static let reuseIdentifier = "MessageCell"
    private let bubble = UIView()
    private let messageLabel = UILabel()
    private let timeLabel = UILabel()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 14
        contentView.addSubview(bubble)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.textColor = MeshTheme.primaryText
        bubble.addSubview(messageLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        bubble.addSubview(timeLabel)

        leading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),
            messageLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            timeLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 4),
            timeLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
            timeLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bubble.leadingAnchor, constant: 12),
        ])
    }

    func configure(with message: DemoMessage) {
        messageLabel.text = message.text
        timeLabel.text = message.time + (message.outgoing ? "  \u{2713}\u{2713}" : "")
        leading.isActive = false
        trailing.isActive = false
        leading.isActive = !message.outgoing
        trailing.isActive = message.outgoing
        bubble.backgroundColor = message.outgoing ? MeshTheme.outgoing : MeshTheme.incoming
    }

    required init?(coder: NSCoder) { nil }
}
