import UIKit

struct ChatPreview {
    let name: String
    let message: String
    let time: String
    let unread: Int
    let color: UIColor
}

struct DemoMessage {
    let text: String
    let time: String
    let outgoing: Bool
}

enum DemoData {
    static let chats: [ChatPreview] = [
        .init(name: "LOSYARA1", message: "See you near the station", time: "20:05", unread: 3, color: MeshTheme.cyan),
        .init(name: "Timofey", message: "The native prototype is ready", time: "19:48", unread: 0, color: MeshTheme.purple),
        .init(name: "MeshChat Support", message: "Welcome to MeshChat", time: "17:10", unread: 1, color: UIColor.systemPink),
        .init(name: "Design group", message: "Photo", time: "16:42", unread: 4, color: UIColor.systemGreen),
        .init(name: "Bluetooth device", message: "Nearby chat connected", time: "15:30", unread: 0, color: UIColor(red: 0.18, green: 0.68, blue: 0.67, alpha: 1)),
        .init(name: "Pavel Durov", message: "Performance first", time: "14:17", unread: 0, color: UIColor(red: 0.34, green: 0.35, blue: 0.82, alpha: 1)),
        .init(name: "Saved Messages", message: "Build notes", time: "12:08", unread: 0, color: UIColor.systemOrange),
    ]

    static let messages: [DemoMessage] = [
        .init(text: "This screen is rendered entirely by UIKit.", time: "19:54", outgoing: false),
        .init(text: "No Flutter engine and no plugin work in the background.", time: "19:55", outgoing: false),
        .init(text: "So we can compare scrolling, transitions and heat fairly.", time: "19:56", outgoing: true),
        .init(text: "Try opening the profile and rapidly scrolling this conversation.", time: "19:57", outgoing: false),
        .init(text: "On iPhone 6 the target is a stable 60 FPS.", time: "19:58", outgoing: true),
        .init(text: "On ProMotion devices the monitor can report up to 120 FPS.", time: "19:59", outgoing: true),
        .init(text: "The production server is intentionally disconnected in this lab build.", time: "20:01", outgoing: false),
        .init(text: "If this remains cool and smooth, we can migrate one production surface at a time.", time: "20:02", outgoing: true),
    ]
}
