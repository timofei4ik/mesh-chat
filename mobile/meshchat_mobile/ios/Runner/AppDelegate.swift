import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioSessionChannel = "meshchat/audio_session"
  private let proximityScreenChannel = "meshchat/proximity_screen"
  private let platformStyleChannel = "meshchat/platform_style"
  private let liquidGlassViewType = "meshchat/liquid_glass"
  private var systemCallBridge: MeshSystemCallBridge?
  private var applePushBridge: MeshApplePushBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      installAudioSessionChannel(controller.binaryMessenger)
      installProximityScreenChannel(controller.binaryMessenger)
      installPlatformStyleChannel(controller.binaryMessenger)
      installApplePushChannel(controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshChatAudioSession") {
      installAudioSessionChannel(registrar.messenger())
      installProximityScreenChannel(registrar.messenger())
      installPlatformStyleChannel(registrar.messenger())
      installApplePushChannel(registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshChatLiquidGlass") {
      registrar.register(MeshChatLiquidGlassFactory(messenger: registrar.messenger()), withId: liquidGlassViewType)
    }
  }

  private func installAudioSessionChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: audioSessionChannel, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "activateCallAudio":
          let arguments = call.arguments as? [String: Any]
          try self.activateCallAudio(speakerEnabled: arguments?["speakerEnabled"] as? Bool ?? true)
          result(nil)
        case "deactivateCallAudio":
          try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(
          FlutterError(
            code: "audio_session",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private func installProximityScreenChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: proximityScreenChannel, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "enable":
        DispatchQueue.main.async {
          UIDevice.current.isProximityMonitoringEnabled = true
          result(nil)
        }
      case "disable":
        DispatchQueue.main.async {
          UIDevice.current.isProximityMonitoringEnabled = false
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func installPlatformStyleChannel(_ messenger: FlutterBinaryMessenger) {
    if systemCallBridge == nil { systemCallBridge = MeshSystemCallBridge(messenger: messenger) }
    let channel = FlutterMethodChannel(name: platformStyleChannel, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getVisualCapabilities":
        result([
          "iosMajorVersion": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
          "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func installApplePushChannel(_ messenger: FlutterBinaryMessenger) {
    if applePushBridge == nil {
      applePushBridge = MeshApplePushBridge(
        messenger: messenger,
        systemCalls: systemCallBridge
      )
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
    applePushBridge?.didRegisterAlertToken(deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
    applePushBridge?.didFailToRegister(error)
  }

  private func activateCallAudio(speakerEnabled: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: speakerEnabled ? [.defaultToSpeaker, .allowBluetooth] : [.allowBluetooth]
    )
    try session.setPreferredSampleRate(48000)
    try session.setPreferredIOBufferDuration(0.01)
    try session.setActive(true, options: [])
    let externalOutput = session.currentRoute.outputs.contains {
      $0.portType == .bluetoothHFP || $0.portType == .headphones || $0.portType == .usbAudio
    }
    try session.overrideOutputAudioPort(speakerEnabled && !externalOutput ? .speaker : .none)
  }
}

// Dormant until the authenticated Flutter call coordinator explicitly reports a call.
private final class MeshSystemCallBridge: NSObject, CXProviderDelegate {
  private let channel: FlutterMethodChannel
  private var provider: CXProvider?
  private var calls: [UUID: String] = [:]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "meshchat/system_calls", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      let args = call.arguments as? [String: Any] ?? [:]
      guard let id = args["callId"] as? String, let uuid = UUID(uuidString: id) else {
        result(FlutterError(code: "invalid_call", message: "Expected call UUID", details: nil))
        return
      }
      switch call.method {
      case "incoming":
        self.reportIncoming(
          callId: id,
          name: args["name"] as? String ?? "MeshChat"
        ) { accepted in
          result(accepted)
        }
      case "ended":
        self.calls.removeValue(forKey: uuid)
        self.provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  func reportIncoming(
    callId: String,
    name: String,
    completion: @escaping (Bool) -> Void
  ) {
    guard let uuid = UUID(uuidString: callId) else {
      completion(false)
      return
    }
    if calls[uuid] != nil {
      completion(true)
      return
    }
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: name)
    update.localizedCallerName = name
    update.hasVideo = false
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    calls[uuid] = callId
    callProvider().reportNewIncomingCall(with: uuid, update: update) {
      [weak self] error in
      DispatchQueue.main.async {
        if error != nil { self?.calls.removeValue(forKey: uuid) }
        completion(error == nil)
      }
    }
  }

  func reportEnded(callId: String) {
    guard let uuid = UUID(uuidString: callId) else { return }
    calls.removeValue(forKey: uuid)
    provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
  }

  private func callProvider() -> CXProvider {
    if let provider = provider { return provider }
    let config = CXProviderConfiguration(localizedName: "MeshChat")
    config.supportsVideo = false
    config.maximumCallsPerCallGroup = 1
    config.maximumCallGroups = 1
    config.supportedHandleTypes = [.generic]
    let created = CXProvider(configuration: config)
    created.setDelegate(self, queue: .main)
    provider = created
    return created
  }

  func providerDidReset(_ provider: CXProvider) {
    calls.removeAll()
    channel.invokeMethod("reset", arguments: ["callId": ""])
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    channel.invokeMethod("answer", arguments: ["callId": calls[action.callUUID] ?? action.callUUID.uuidString.lowercased()]) { response in
      if response as? Bool == true { action.fulfill() } else { action.fail() }
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    channel.invokeMethod("end", arguments: ["callId": calls[action.callUUID] ?? action.callUUID.uuidString.lowercased()]) { response in
      if response as? Bool == true {
        self.calls.removeValue(forKey: action.callUUID)
        action.fulfill()
      } else { action.fail() }
    }
  }
}

// Registration stays dormant until Flutter is built with
// --dart-define=MESH_ENABLE_APPLE_PUSH=true.
private final class MeshApplePushBridge: NSObject, PKPushRegistryDelegate {
  private let channel: FlutterMethodChannel
  private weak var systemCalls: MeshSystemCallBridge?
  private var voipRegistry: PKPushRegistry?

  init(
    messenger: FlutterBinaryMessenger,
    systemCalls: MeshSystemCallBridge?
  ) {
    channel = FlutterMethodChannel(
      name: "meshchat/apple_push",
      binaryMessenger: messenger
    )
    self.systemCalls = systemCalls
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "initialize" else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
        let args = call.arguments as? [String: Any]
        if args?["enableVoip"] as? Bool == true {
          self?.registerVoipPushes()
        }
        result(nil)
      }
    }
  }

  func didRegisterAlertToken(_ data: Data) {
    emitToken(data, kind: "alert")
  }

  func didFailToRegister(_ error: Error) {
    channel.invokeMethod(
      "registrationFailed",
      arguments: ["message": error.localizedDescription]
    )
  }

  private func registerVoipPushes() {
    if voipRegistry != nil { return }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
  }

  private func emitToken(_ data: Data, kind: String) {
    let token = data.map { String(format: "%02x", $0) }.joined()
    #if DEBUG
      let environment = "sandbox"
    #else
      let environment = "production"
    #endif
    channel.invokeMethod(
      "token",
      arguments: [
        "token": token,
        "kind": kind,
        "environment": environment,
      ]
    )
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    emitToken(pushCredentials.token, kind: "voip")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    guard type == .voIP else { return }
    channel.invokeMethod(
      "tokenInvalidated",
      arguments: ["kind": "voip"]
    )
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    let raw = payload.dictionaryPayload
    let packetType = raw["type"] as? String ?? ""
    let callId = raw["call_id"] as? String ?? ""
    if packetType == "call_end" {
      systemCalls?.reportEnded(callId: callId)
      completion()
      return
    }
    guard packetType == "call_offer", UUID(uuidString: callId) != nil else {
      completion()
      return
    }
    let expiresAt = (raw["expires_at"] as? NSNumber)?.doubleValue ?? 0
    if expiresAt > 0 && expiresAt <= Date().timeIntervalSince1970 {
      completion()
      return
    }
    guard let systemCalls = systemCalls else {
      completion()
      return
    }
    let caller = raw["caller_name"] as? String ?? "MeshChat"
    systemCalls.reportIncoming(callId: callId, name: caller) {
      [weak self] _ in
      self?.channel.invokeMethod(
        "notificationOpened",
        arguments: self?.flutterPayload(raw) ?? [:]
      )
      completion()
    }
  }

  private func flutterPayload(
    _ raw: [AnyHashable: Any]
  ) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in raw {
      guard let key = key as? String else { continue }
      result[key] = value
    }
    return result
  }
}

private final class MeshChatLiquidGlassFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MeshChatLiquidGlassView(frame: frame, arguments: args, viewId: viewId, messenger: messenger)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class MeshChatLiquidGlassView: NSObject, FlutterPlatformView {
  private let rootView: UIView
  private let effectView: UIVisualEffectView
  private let channel: FlutterMethodChannel

  init(frame: CGRect, arguments args: Any?, viewId: Int64, messenger: FlutterBinaryMessenger) {
    rootView = UIView(frame: frame)
    effectView = UIVisualEffectView(effect: nil)
    channel = FlutterMethodChannel(name: "meshchat/liquid_glass/\(viewId)", binaryMessenger: messenger)
    super.init()

    let values = args as? [String: Any]
    let radius = CGFloat((values?["radius"] as? NSNumber)?.doubleValue ?? 22)
    let interactive = (values?["interactive"] as? NSNumber)?.boolValue ?? true
    let tint = Self.color(fromARGB: values?["tint"] as? NSNumber)

    rootView.backgroundColor = .clear
    rootView.isUserInteractionEnabled = false
    rootView.clipsToBounds = true
    rootView.layer.cornerRadius = radius
    rootView.layer.cornerCurve = .continuous

    effectView.frame = rootView.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.overrideUserInterfaceStyle = .dark
    effectView.isUserInteractionEnabled = false
    effectView.clipsToBounds = true
    effectView.layer.cornerRadius = radius
    effectView.layer.cornerCurve = .continuous
    rootView.addSubview(effectView)
    let shade = UIView(frame: rootView.bounds)
    shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    shade.isUserInteractionEnabled = false
    let shadeAlpha = (values?["shade"] as? NSNumber)?.doubleValue ?? 0.24
    shade.backgroundColor = UIColor(red: 0.06, green: 0.10, blue: 0.14, alpha: CGFloat(shadeAlpha))
    rootView.addSubview(shade)

    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        let glassEffect = UIGlassEffect()
        glassEffect.tintColor = tint
        glassEffect.isInteractive = interactive
        effectView.cornerConfiguration = .corners(
          radius: .fixed(Double(radius))
        )
        effectView.effect = glassEffect
      } else {
        effectView.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
      }
    #else
      effectView.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    #endif

    // Capture only the material, never Flutter labels or chat contents. During
    // interactive routes Flutter displays this image below the foreground page.
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "snapshot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self, self.rootView.window != nil else { result(nil); return }
      let size = self.rootView.bounds.size
      guard size.width > 0, size.height > 0,
            size.width <= 2048, size.height <= 2048 else { result(nil); return }
      let format = UIGraphicsImageRendererFormat()
      format.scale = min(self.rootView.window?.screen.scale ?? 2, 2)
      format.opaque = false
      let renderer = UIGraphicsImageRenderer(size: size, format: format)
      let image = renderer.image { _ in
        self.rootView.drawHierarchy(in: self.rootView.bounds, afterScreenUpdates: false)
      }
      if let data = image.pngData() { result(FlutterStandardTypedData(bytes: data)) }
      else { result(nil) }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }

  func view() -> UIView {
    return rootView
  }

  private static func color(fromARGB value: NSNumber?) -> UIColor {
    guard let argb = value?.uint32Value else {
      return UIColor(red: 0.08, green: 0.14, blue: 0.22, alpha: 0.12)
    }
    let alpha = CGFloat((argb >> 24) & 0xff) / 255
    let red = CGFloat((argb >> 16) & 0xff) / 255
    let green = CGFloat((argb >> 8) & 0xff) / 255
    let blue = CGFloat(argb & 0xff) / 255
    return UIColor(red: red, green: green, blue: blue, alpha: alpha)
  }
}
