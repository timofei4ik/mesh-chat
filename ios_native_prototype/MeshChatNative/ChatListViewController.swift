import UIKit

final class ChatListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let fpsLabel = UILabel()
    private let monitor = FPSMonitor()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeshTheme.background
        buildHeader()
        buildTable()

        monitor.onUpdate = { [weak self] fps in
            self?.fpsLabel.text = "NATIVE LAB  \(fps) FPS"
            self?.fpsLabel.textColor = fps >= 55 ? UIColor.systemGreen : UIColor.systemOrange
        }
        monitor.start()
    }

    private func buildHeader() {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let logo = UIImageView(image: UIImage(named: "Logo"))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.layer.cornerRadius = 24
        logo.clipsToBounds = true
        logo.contentMode = .scaleAspectFill

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "MeshChat"
        title.textColor = MeshTheme.primaryText
        title.font = MeshTheme.titleFont(25)

        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsLabel.text = "NATIVE LAB"
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        fpsLabel.textColor = MeshTheme.cyan

        let profileButton = UIButton(type: .system)
        profileButton.translatesAutoresizingMaskIntoConstraints = false
        MeshTheme.setIcon(on: profileButton, name: "person.crop.circle", fallback: "Me")
        profileButton.tintColor = MeshTheme.primaryText
        profileButton.backgroundColor = MeshTheme.surface
        profileButton.layer.cornerRadius = 22
        profileButton.addTarget(self, action: #selector(openOwnProfile), for: .touchUpInside)

        [logo, title, fpsLabel, profileButton].forEach(header.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            header.heightAnchor.constraint(equalToConstant: 76),
            logo.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            logo.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 48),
            logo.heightAnchor.constraint(equalToConstant: 48),
            title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: logo.topAnchor, constant: 2),
            fpsLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            fpsLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            profileButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            profileButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            profileButton.widthAnchor.constraint(equalToConstant: 44),
            profileButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        let search = UISearchBar()
        search.translatesAutoresizingMaskIntoConstraints = false
        search.searchBarStyle = .minimal
        search.placeholder = "Search"
        search.tintColor = MeshTheme.cyan
        if #available(iOS 13.0, *) {
            search.searchTextField.textColor = MeshTheme.primaryText
            search.searchTextField.backgroundColor = MeshTheme.surface
        }
        view.addSubview(search)

        let filter = UISegmentedControl(items: ["All", "Personal", "Groups"])
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.selectedSegmentIndex = 0
        if #available(iOS 13.0, *) {
            filter.selectedSegmentTintColor = MeshTheme.raisedSurface
        } else {
            filter.tintColor = MeshTheme.raisedSurface
        }
        filter.setTitleTextAttributes([.foregroundColor: MeshTheme.secondaryText], for: .normal)
        filter.setTitleTextAttributes([.foregroundColor: MeshTheme.cyan], for: .selected)
        view.addSubview(filter)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: header.bottomAnchor),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            filter.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            filter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            filter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            filter.heightAnchor.constraint(equalToConstant: 38),
        ])

        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildTable() {
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 20, right: 0)
        tableView.rowHeight = 82
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ChatPreviewCell.self, forCellReuseIdentifier: ChatPreviewCell.reuseIdentifier)
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
        card.backgroundColor = MeshTheme.surface
        card.layer.cornerRadius = 14
        contentView.addSubview(card)

        [nameLabel, previewLabel, timeLabel, unreadLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        nameLabel.textColor = MeshTheme.primaryText
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
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
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 72),
            nameLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            previewLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            previewLabel.trailingAnchor.constraint(equalTo: unreadLabel.leadingAnchor, constant: -8),
            timeLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            timeLabel.topAnchor.constraint(equalTo: nameLabel.topAnchor, constant: 2),
            unreadLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            unreadLabel.centerYAnchor.constraint(equalTo: previewLabel.centerYAnchor),
            unreadLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            unreadLabel.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func configure(with chat: ChatPreview) {
        avatar?.removeFromSuperview()
        let avatar = InitialAvatarView(text: chat.name, color: chat.color, size: 48)
        card.addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            avatar.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        self.avatar = avatar
        nameLabel.text = chat.name
        previewLabel.text = chat.message
        timeLabel.text = chat.time
        unreadLabel.text = chat.unread > 0 ? "\(chat.unread)" : nil
        unreadLabel.isHidden = chat.unread == 0
    }

    required init?(coder: NSCoder) { nil }
}
