import UIKit

final class ProfileViewController: UIViewController {
    private let name: String
    private let handle: String
    private let color: UIColor
    private let scrollView = UIScrollView()
    private let avatarContainer = UIView()
    private var avatarSize: NSLayoutConstraint!
    private var expanded = false

    init(name: String, handle: String, color: UIColor) {
        self.name = name
        self.handle = handle
        self.color = color
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeshTheme.background
        view.addSubview(MeshBackdropView(frame: view.bounds))
        buildHeader()
        buildContent()
    }

    private func buildHeader() {
        let back = UIButton(type: .system)
        back.translatesAutoresizingMaskIntoConstraints = false
        MeshTheme.setIcon(on: back, name: "chevron.left", fallback: "<")
        back.tintColor = MeshTheme.primaryText
        back.backgroundColor = MeshTheme.surface
        back.layer.cornerRadius = 22
        back.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        view.addSubview(back)
        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            back.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func buildContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.insertSubview(scrollView, at: 0)
        scrollView.pinEdges(to: view)

        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        let hero = UIView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.backgroundColor = MeshTheme.surface
        hero.layer.cornerRadius = 20
        hero.layer.borderWidth = 1
        hero.layer.borderColor = color.withAlphaComponent(0.35).cgColor
        hero.clipsToBounds = true
        content.addSubview(hero)

        let heroBackdrop = MeshBackdropView(frame: .zero)
        hero.addSubview(heroBackdrop)
        heroBackdrop.pinEdges(to: hero)

        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.backgroundColor = color
        avatarContainer.layer.cornerRadius = 48
        avatarContainer.layer.borderWidth = 2
        avatarContainer.layer.borderColor = MeshTheme.cyan.withAlphaComponent(0.65).cgColor
        avatarContainer.clipsToBounds = true
        hero.addSubview(avatarContainer)

        let initial = UILabel()
        initial.translatesAutoresizingMaskIntoConstraints = false
        initial.text = String(name.prefix(1)).uppercased()
        initial.font = .systemFont(ofSize: 42, weight: .bold)
        initial.textColor = .white
        initial.textAlignment = .center
        avatarContainer.addSubview(initial)
        initial.pinEdges(to: avatarContainer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleAvatar))
        avatarContainer.addGestureRecognizer(tap)

        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.text = name
        nameLabel.font = MeshTheme.titleFont(24)
        nameLabel.textColor = MeshTheme.primaryText
        nameLabel.textAlignment = .center
        hero.addSubview(nameLabel)

        let handleLabel = UILabel()
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.text = handle
        handleLabel.font = .systemFont(ofSize: 14)
        handleLabel.textColor = MeshTheme.secondaryText
        handleLabel.textAlignment = .center
        hero.addSubview(handleLabel)

        avatarSize = avatarContainer.widthAnchor.constraint(equalToConstant: 96)
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: content.topAnchor, constant: 76),
            hero.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hero.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            avatarContainer.topAnchor.constraint(equalTo: hero.topAnchor, constant: 24),
            avatarContainer.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            avatarSize,
            avatarContainer.heightAnchor.constraint(equalTo: avatarContainer.widthAnchor),
            nameLabel.topAnchor.constraint(equalTo: avatarContainer.bottomAnchor, constant: 16),
            nameLabel.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
            handleLabel.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            handleLabel.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -22),
        ])

        let actions = actionRow()
        content.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 14),
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            actions.heightAnchor.constraint(equalToConstant: 74),
        ])

        let about = infoCard(title: "About", value: "Native UIKit performance prototype")
        let username = infoCard(title: "Username", value: handle)
        let media = infoCard(title: "Shared media", value: "Photos 24   Files 8   Voice 13   Links 5")
        [about, username, media].forEach { content.addSubview($0) }
        NSLayoutConstraint.activate([
            about.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 14),
            about.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            about.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            username.topAnchor.constraint(equalTo: about.bottomAnchor, constant: 10),
            username.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            username.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            media.topAnchor.constraint(equalTo: username.bottomAnchor, constant: 10),
            media.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            media.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            media.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
        ])
    }

    private func actionRow() -> UIStackView {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 10
        [("message.fill", "Message"), ("phone.fill", "Call"), ("bell.slash.fill", "Mute")].forEach { item in
            let button = UIButton(type: .system)
            button.backgroundColor = MeshTheme.surface
            button.layer.cornerRadius = 16
            button.tintColor = MeshTheme.cyan
            if #available(iOS 13.0, *) {
                button.setImage(UIImage(systemName: item.0), for: .normal)
            }
            button.setTitle("  \(item.1)", for: .normal)
            button.setTitleColor(MeshTheme.primaryText, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func infoCard(title: String, value: String) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = MeshTheme.surface
        card.layer.cornerRadius = 14

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title
        titleLabel.textColor = MeshTheme.cyan
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        card.addSubview(titleLabel)

        let valueLabel = UILabel()
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.text = value
        valueLabel.textColor = MeshTheme.primaryText
        valueLabel.font = .systemFont(ofSize: 15)
        valueLabel.numberOfLines = 0
        card.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            valueLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -15),
        ])
        return card
    }

    @objc private func toggleAvatar() {
        expanded.toggle()
        avatarSize.constant = expanded ? min(view.bounds.width - 64, 310) : 96
        let animations = {
            self.avatarContainer.layer.cornerRadius = self.expanded ? 22 : 48
            self.view.layoutIfNeeded()
        }
        if MeshTheme.shouldReduceMotion {
            animations()
        } else {
            let animator = UIViewPropertyAnimator(duration: 0.34, dampingRatio: 0.88, animations: animations)
            animator.startAnimation()
        }
        if #available(iOS 10.0, *) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    @objc private func goBack() { navigationController?.popViewController(animated: !MeshTheme.shouldReduceMotion) }
}
