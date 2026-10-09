import Foundation
import Flutter

/// Bridges Dart <-> liblinphone on iOS.
///
/// Mirrors the Android `SipPlugin` so a single Dart `SipBridge` works on both platforms.
final class SipPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  static let methodChannelName = "io.vicifast.phone/sip"
  static let eventChannelName  = "io.vicifast.phone/sip_events"

  private var eventSink: FlutterEventSink?
  private let manager = LinphoneManager.shared

  static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
    let eventChannel  = FlutterEventChannel(name: eventChannelName,  binaryMessenger: registrar.messenger())
    let plugin = SipPlugin()
    registrar.addMethodCallDelegate(plugin, channel: methodChannel)
    eventChannel.setStreamHandler(plugin)

    LinphoneManager.shared.onEvent = { [weak plugin] event in
      DispatchQueue.main.async { plugin?.eventSink?(event) }
    }
  }

  // Convenience for the AppDelegate's implicit-engine pattern.
  func register(with registrar: FlutterPluginRegistrar) {
    SipPlugin.register(with: registrar)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "start":
        manager.start()
        result(nil)
      case "stop":
        manager.stop()
        result(nil)
      case "register":
        guard let a = call.arguments as? [String: Any],
              let username = a["username"] as? String,
              let password = a["password"] as? String,
              let domain   = a["domain"]   as? String
        else { return result(FlutterError(code: "BAD_ARGS", message: "Missing fields", details: nil)) }
        try manager.register(
          username: username,
          password: password,
          domain:   domain,
          proxy:    a["proxy"] as? String,
          transport: (a["transport"] as? String) ?? "udp",
          port:     a["port"] as? Int
        )
        result(nil)
      case "unregister":
        manager.unregister(); result(nil)
      case "forceRefresh":
        manager.forceRefresh(); result(nil)
      case "softReconnect":
        manager.softReconnect(); result(nil)
      case "verifyRegistration":
        manager.verifyRegistration(); result(nil)
      case "wipeAccount":
        manager.wipeAccount(); result(nil)
      case "call":
        guard let to = (call.arguments as? [String: Any])?["to"] as? String
        else { return result(FlutterError(code: "BAD_ARGS", message: "to required", details: nil)) }
        let id = manager.placeCall(to: to)
        result(id)
      case "answer":
        manager.answer(); result(nil)
      case "hangup":
        manager.hangup(); result(nil)
      case "dtmf":
        if let d = (call.arguments as? [String: Any])?["digit"] as? String, let ch = d.first {
          manager.sendDtmf(ch)
        }
        result(nil)
      case "setMute":
        let m = ((call.arguments as? [String: Any])?["muted"] as? Bool) ?? false
        manager.setMute(m); result(nil)
      case "setHold":
        let on = ((call.arguments as? [String: Any])?["on"] as? Bool) ?? false
        manager.setHold(on); result(nil)
      case "setSpeaker":
        let on = ((call.arguments as? [String: Any])?["on"] as? Bool) ?? false
        manager.setSpeaker(on); result(nil)
      case "registrationState":
        result(manager.registrationState)
      case "currentCall":
        result(manager.currentCallSnapshot())
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "SIP_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  // MARK: FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    // Replay the push token Dart missed while it wasn't listening yet.
    if let token = manager.lastVoipToken {
      events(["type": "voipToken", "token": token, "platform": "apns"])
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
