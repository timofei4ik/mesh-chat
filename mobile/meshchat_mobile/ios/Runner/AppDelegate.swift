import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioSessionChannel = "meshchat/audio_session"
  private let proximityScreenChannel = "meshchat/proximity_screen"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      installAudioSessionChannel(controller.binaryMessenger)
      installProximityScreenChannel(controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshChatAudioSession") {
      installAudioSessionChannel(registrar.messenger())
      installProximityScreenChannel(registrar.messenger())
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
