import UIKit

final class ChatListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let monitor = FPSMonitor()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeshTheme.background
        view.addSubview(MeshBackdropView(frame: view.bounds))
        buildTable()
        buildBottomBar()
        monitor.start()
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 104, right: 0)
        tableView.verticalScrollIndicatorInsets.bottom = 92
        tableView.rowHeight = 96
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ChatPreviewCell.self, forCellReuseIdentifier: ChatPreviewCell.reuseIdentifier)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let width = max(view.bounds.width, 320)
        let header = HomeHeaderView(frame: CGRect(x: 0, y: 0, width: width, height: 326))
        header.onProfile = { [weak self] in self?.openOwnProfile() }
        tableView.tableHeaderView = header
    }

    private func buildBottomBar() {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = MeshTheme.surface.withAlphaComponent(0.97)
        bar.layer.cornerRadius = 28
        bar.layer.borderWidth = 1
        bar.layer.borderColor = MeshTheme.cyan.withAlphaComponent(0.3).cgColor
        view.addSubview(bar)

        let indicator = UIView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.backgroundColor = MeshTheme.cyan.withAlphaComponent(0.16)
        indicator.layer.cornerRadius = 21
        indicator.layer.borderWidth = 1
        indicator.layer.borderColor = MeshTheme.cyan.withAlphaComponent(0.28).cgColor
        bar.addSubview(indicator)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        bar.addSubview(stack)

        let chats = navButton(icon: "bubble.left.and.bubble.right.fill", fallback: "Chats", title: "Chats", selected: true)
        let settings = navButton(icon: "gearshape.fill", fallback: "Settings", title: "Settings", selected: false)
        let bluetooth = navButton(icon: "bolt.horizontal.circle.fill", fallback: "Bluetooth", title: "Bluetooth", selected: false)
        [chats, settings, bluetooth].forEach { stack.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 78),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 7),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -7),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -7),
            indicator.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            indicator.topAnchor.constraint(equalTo: stack.topAnchor),
            indicator.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 1 / 3),
        ])
    }

    private func navButton(icon: String, fallback: String, title: String, selected: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = selected ? MeshTheme.cyan : MeshTheme.secondaryText
        button.setTitle("\n\(title)", for: .normal)
        button.setTitleColor(selected ? MeshTheme.cyan : MeshTheme.secondaryText, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        if #available(iOS 13.0, *) {
            button.setImage(UIImage(systemName: icon), for: .normal)
            button.imageEdgeInsets = UIEdgeInsets(top: -17, left: 38, bottom: 0, right: 0)
            button.titleEdgeInsets = UIEdgeInsets(top: 24, left: -15, bottom: 0, right: 0)
        }
        return button
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { DemoData.chats.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChatPreviewCell.reuseIdentifier, for: indexPath) as! ChatPreviewCell
        cell.configure(with: DemoData.chats[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(ChatViewController(chat: DemoData.chats[indexPath.row]), animated: !MeshTheme.shouldReduceMotion)
    }

    @objc private func openOwnProfile() {
        navigationController?.pushViewController(ProfileViewController(name: "Timofey", handle: "@sundrieddd", color: MeshTheme.cyan), animated: !MeshTheme.shouldReduceMotion)
    }
}

private final class HomeHeaderView: UIView {
    var onProfile: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let logo = UIImageView(image: UIImage(named: "Logo"))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.layer.cornerRadius = 27
        logo.clipsToBounds = true
        logo.contentMode = .scaleAspectFill
        addSubview(logo)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "MeshChat"
        title.textColor = MeshTheme.primaryText
        title.font = MeshTheme.titleFont(26)
        addSubview(title)

        let bluetooth = UIView()
        bluetooth.translatesAutoresizingMaskIntoConstraints = false
        bluetooth.backgroundColor = MeshTheme.surface
        bluetooth.layer.cornerRadius = 16
        bluetooth.layer.borderWidth = 1
        bluetooth.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        addSubview(bluetooth)

        let btIcon = UILabel()
        btIcon.translatesAutoresizingMaskIntoConstraints = false
        btIcon.text = "B"
        btIcon.textColor = .white
        btIcon.font = .systemFont(ofSize: 18, weight: .medium)
        bluetooth.addSubview(btIcon)
        let btTitle = label("Bluetooth", size: 11, color: MeshTheme.secondaryText, weight: .regular)
        let btState = label("Off  *", size: 10, color: UIColor.systemGreen, weight: .bold)
        bluetooth.addSubview(btTitle)
        bluetooth.addSubview(btState)

        let add = UIButton(type: .system)
        add.translatesAutoresizingMaskIntoConstraints = false
        add.setTitle("+", for: .normal)
        add.titleLabel?.font = .systemFont(ofSize: 31, weight: .light)
        add.setTitleColor(MeshTheme.primaryText, for: .normal)
        add.backgroundColor = MeshTheme.surface
        add.layer.cornerRadius = 23
        add.layer.borderWidth = 1
        add.layer.borderColor = MeshTheme.cyan.withAlphaComponent(0.25).cgColor
        add.addTarget(self, action: #selector(profileTapped), for: .touchUpInside)
        self.addSubview(add)

        let search = UIView()
        search.translatesAutoresizingMaskIntoConstraints = false
        search.backgroundColor = MeshTheme.surface.withAlphaComponent(0.92)
        search.layer.cornerRadius = 18
        search.layer.borderWidth = 1
        search.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        addSubview(search)
        let searchText = label("  Search", size: 14, color: MeshTheme.secondaryText, weight: .regular)
        search.addSubview(searchText)

        let status = label("  *  Online  ", size: 12, color: UIColor.systemGreen, weight: .semibold)
        status.backgroundColor = MeshTheme.surface
        status.layer.cornerRadius = 14
        status.layer.masksToBounds = true
        addSubview(status)

        let filters = UIStackView()
        filters.translatesAutoresizingMaskIntoConstraints = false
        filters.axis = .horizontal
        filters.distribution = .fillEqually
        filters.spacing = 8
        ["All", "Personal", "Groups", "Channels"].enumerated().forEach { item in
            let index = item.offset
            let text = item.element
            let button = UIButton(type: .system)
            button.setTitle(text, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            button.setTitleColor(index == 0 ? MeshTheme.cyan : MeshTheme.secondaryText, for: .normal)
            button.backgroundColor = index == 0 ? MeshTheme.cyan.withAlphaComponent(0.14) : MeshTheme.surface
            button.layer.cornerRadius = 17
            button.layer.borderWidth = 1
            button.layer.borderColor = (index == 0 ? MeshTheme.cyan : UIColor.white).withAlphaComponent(0.2).cgColor
            filters.addArrangedSubview(button)
        }
        addSubview(filters)

        let story = UIView()
        story.translatesAutoresizingMaskIntoConstraints = false
        story.backgroundColor = MeshTheme.surface
        story.layer.cornerRadius = 21
        story.layer.borderWidth = 1
        story.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        addSubview(story)
        let plus = label("+", size: 34, color: .white, weight: .light)
        plus.textAlignment = .center
        plus.backgroundColor = MeshTheme.cyan.withAlphaComponent(0.23)
        plus.layer.cornerRadius = 25
        plus.layer.masksToBounds = true
        story.addSubview(plus)
        let storyText = label("My story", size: 11, color: MeshTheme.primaryText, weight: .bold)
        storyText.textAlignment = .center
        story.addSubview(storyText)

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            logo.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            logo.widthAnchor.constraint(equalToConstant: 54),
            logo.heightAnchor.constraint(equalToConstant: 54),
            title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            add.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 46),
            add.heightAnchor.constraint(equalToConstant: 46),
            bluetooth.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -8),
            bluetooth.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            bluetooth.widthAnchor.constraint(equalToConstant: 112),
            bluetooth.heightAnchor.constraint(equalToConstant: 50),
            btIcon.leadingAnchor.constraint(equalTo: bluetooth.leadingAnchor, constant: 11),
            btIcon.centerYAnchor.constraint(equalTo: bluetooth.centerYAnchor),
            btTitle.leadingAnchor.constraint(equalTo: btIcon.trailingAnchor, constant: 8),
            btTitle.topAnchor.constraint(equalTo: bluetooth.topAnchor, constant: 9),
            btState.leadingAnchor.constraint(equalTo: btTitle.leadingAnchor),
            btState.topAnchor.constraint(equalTo: btTitle.bottomAnchor, constant: 2),
            search.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            search.heightAnchor.constraint(equalToConstant: 42),
            searchText.leadingAnchor.constraint(equalTo: search.leadingAnchor, constant: 12),
            searchText.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            status.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            status.heightAnchor.constraint(equalToConstant: 28),
            filters.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 11),
            filters.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            filters.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            filters.heightAnchor.constraint(equalToConstant: 36),
            story.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 12),
            story.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            story.widthAnchor.constraint(equalToConstant: 88),
            story.heightAnchor.constraint(equalToConstant: 105),
            plus.topAnchor.constraint(equalTo: story.topAnchor, constant: 10),
            plus.centerXAnchor.constraint(equalTo: story.centerXAnchor),
            plus.widthAnchor.constraint(equalToConstant: 50),
            plus.heightAnchor.constraint(equalToConstant: 50),
            storyText.topAnchor.constraint(equalTo: plus.bottomAnchor, constant: 8),
            storyText.centerXAnchor.constraint(equalTo: story.centerXAnchor),
        ])
    }

    private func label(_ text: String, size: CGFloat, color: UIColor, weight: UIFont.Weight) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = color
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    @objc private func profileTapped() { onProfile?() }
}

final class ChatPreviewCell: UITableViewCell {
    static let reuseIdentifier = "ChatPreviewCell"
    private let card = UIView()
    private var avatar: InitialAvatarView?
    private let nameLabel = UILabel()
    private let previewLabel = UILabel()
    private let timeLabel = UILabel()
    private let unreadLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = MeshTheme.surface.withAlphaComponent(0.96)
        card.layer.cornerRadius = 24
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        contentView.addSubview(card)
        [nameLabel, previewLabel, timeLabel, unreadLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; card.addSubview($0) }
        nameLabel.textColor = MeshTheme.primaryText
        nameLabel.font = .systemFont(ofSize: 16, weight: .bold)
        previewLabel.textColor = MeshTheme.secondaryText
        previewLabel.font = .systemFont(ofSize: 14)
        previewLabel.lineBreakMode = .byTruncatingTail
        timeLabel.textColor = MeshTheme.secondaryText
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        unreadLabel.textColor = .white
        unreadLabel.font = .systemFont(ofSize: 11, weight: .bold)
        unreadLabel.textAlignment = .center
        unreadLabel.backgroundColor = MeshTheme.outgoing
        unreadLabel.layer.cornerRadius = 10
        unreadLabel.clipsToBounds = true
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5), card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12), card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 78), nameLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 17),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            previewLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), previewLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 7),
            previewLabel.trailingAnchor.constraint(equalTo: unreadLabel.leadingAnchor, constant: -8),
            timeLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -15), timeLabel.topAnchor.constraint(equalTo: nameLabel.topAnchor, constant: 2),
            unreadLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -15), unreadLabel.centerYAnchor.constraint(equalTo: previewLabel.centerYAnchor),
            unreadLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20), unreadLabel.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func configure(with chat: ChatPreview) {
        avatar?.removeFromSuperview()
        let avatar = InitialAvatarView(text: chat.name, color: chat.color, size: 56)
        card.addSubview(avatar)
        NSLayoutConstraint.activate([avatar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), avatar.centerYAnchor.constraint(equalTo: card.centerYAnchor)])
        self.avatar = avatar
        nameLabel.text = chat.name
        previewLabel.text = chat.message
        timeLabel.text = chat.time
        unreadLabel.text = chat.unread > 0 ? "\(chat.unread)" : nil
        unreadLabel.isHidden = chat.unread == 0
    }

    required init?(coder: NSCoder) { nil }
}
