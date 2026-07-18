import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioSessionChannel = "meshchat/audio_session"
  private let proximityScreenChannel = "meshchat/proximity_screen"
  private let platformStyleChannel = "meshchat/platform_style"
  private let liquidGlassViewType = "meshchat/liquid_glass"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      installAudioSessionChannel(controller.binaryMessenger)
      installProximityScreenChannel(controller.binaryMessenger)
      installPlatformStyleChannel(controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshChatAudioSession") {
      installAudioSessionChannel(registrar.messenger())
      installProximityScreenChannel(registrar.messenger())
      installPlatformStyleChannel(registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshChatLiquidGlass") {
      registrar.register(MeshChatLiquidGlassFactory(), withId: liquidGlassViewType)
    }
  }

  private func installAudioSessionChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: audioSessionChannel, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "activateCallAudio":
          try self.activateCallAudio()
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

  private func activateCallAudio() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
    )
    try session.setPreferredSampleRate(48000)
    try session.setPreferredIOBufferDuration(0.01)
    try session.setActive(true, options: [])
    try session.overrideOutputAudioPort(.speaker)
  }
}

private final class MeshChatLiquidGlassFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MeshChatLiquidGlassView(frame: frame, arguments: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class MeshChatLiquidGlassView: NSObject, FlutterPlatformView {
  private let rootView: UIView
  private let effectView: UIVisualEffectView

  init(frame: CGRect, arguments args: Any?) {
    rootView = UIView(frame: frame)
    effectView = UIVisualEffectView(effect: nil)
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
  }

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
