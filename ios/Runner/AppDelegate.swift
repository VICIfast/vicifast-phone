import Flutter
import UIKit
import PushKit
import CallKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  /// Bridge that owns LinphoneManager + CallKitManager + PushKitManager.
  private var sip: SipPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Initialise PushKit eagerly so the VoIP push registry survives cold launches
    // triggered by an incoming-call push payload.
    PushKitManager.shared.register()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Attach our native SIP plugin to the platform channel
    sip = SipPlugin()
    sip?.register(with: engineBridge.pluginRegistry.registrar(forPlugin: "SipPlugin")!)
  }
}
