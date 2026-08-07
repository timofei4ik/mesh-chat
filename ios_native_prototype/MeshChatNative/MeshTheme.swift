import UIKit

enum MeshTheme {
    static let background = UIColor(red: 7 / 255, green: 18 / 255, blue: 32 / 255, alpha: 1)
    static let surface = UIColor(red: 21 / 255, green: 37 / 255, blue: 54 / 255, alpha: 1)
    static let raisedSurface = UIColor(red: 29 / 255, green: 47 / 255, blue: 65 / 255, alpha: 1)
    static let outgoing = UIColor(red: 25 / 255, green: 119 / 255, blue: 204 / 255, alpha: 1)
    static let incoming = UIColor(red: 37 / 255, green: 48 / 255, blue: 62 / 255, alpha: 1)
    static let cyan = UIColor(red: 54 / 255, green: 203 / 255, blue: 239 / 255, alpha: 1)
    static let purple = UIColor(red: 155 / 255, green: 95 / 255, blue: 255 / 255, alpha: 1)
    static let primaryText = UIColor(white: 0.96, alpha: 1)
    static let secondaryText = UIColor(white: 0.66, alpha: 1)
    static let separator = UIColor(white: 1, alpha: 0.08)

    static var shouldReduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static func titleFont(_ size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .bold)
    }

    static func setIcon(on button: UIButton, name: String, fallback: String) {
        if #available(iOS 13.0, *) {
            button.setImage(UIImage(systemName: name), for: .normal)
        } else {
            button.setTitle(fallback, for: .normal)
        }
    }
}

extension UIView {
    func pinEdges(to view: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top),
            leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -insets.right),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

final class InitialAvatarView: UIView {
    private let label = UILabel()

    init(text: String, color: UIColor, size: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = color
        layer.cornerRadius = size / 2
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        clipsToBounds = true

        label.text = String(text.prefix(1)).uppercased()
        label.textColor = .white
        label.font = .systemFont(ofSize: size * 0.42, weight: .semibold)
        label.textAlignment = .center
        addSubview(label)
        label.pinEdges(to: self)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

final class FPSMonitor {
    var onUpdate: ((Int) -> Void)?
    private var displayLink: CADisplayLink?
    private var frames = 0
    private var lastTimestamp: CFTimeInterval = 0

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 { lastTimestamp = link.timestamp }
        frames += 1
        let elapsed = link.timestamp - lastTimestamp
        guard elapsed >= 1 else { return }
        onUpdate?(Int((Double(frames) / elapsed).rounded()))
        frames = 0
        lastTimestamp = link.timestamp
    }

    deinit { stop() }
}
