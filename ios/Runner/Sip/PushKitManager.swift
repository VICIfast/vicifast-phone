import Foundation
import PushKit
import CallKit

/// PushKit (VoIP push) is the only mechanism iOS supports for waking a killed
/// or suspended app to handle an incoming SIP INVITE while the screen is locked.
///
/// Apple's contract (enforced since iOS 13): when a VoIP push arrives, the app
/// MUST call `CXProvider.reportNewIncomingCall(with:update:completion:)` before
/// returning from `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)`,
/// or the system will throttle/terminate the app.
///
/// Server side: your push gateway sends a VoIP push (topic: <bundle-id>.voip)
/// just before forwarding the SIP INVITE to the device, so the app is alive
/// when the INVITE arrives. liblinphone then reports IncomingReceived to
/// LinphoneManager, which also calls reportIncoming on CallKit. Reporting
/// twice for the same call is fine — CallKit dedupes by UUID.
final class PushKitManager: NSObject, PKPushRegistryDelegate {

  static let shared = PushKitManager()

  private var registry: PKPushRegistry?

  func register() {
    let r = PKPushRegistry(queue: .main)
    r.delegate = self
    r.desiredPushTypes = [.voIP]
    self.registry = r
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let tokenHex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    NSLog("VoIP push token: \(tokenHex)")
    LinphoneManager.shared.setVoipPushToken(tokenHex)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    NSLog("VoIP push token invalidated for type=\(type)")
    // Never replay a token Apple has withdrawn.
    LinphoneManager.shared.clearVoipPushToken()
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    // CRITICAL: must call CallKit.reportNewIncomingCall synchronously before returning,
    // even if the SIP INVITE hasn't arrived yet — otherwise iOS will kill the app.
    // No callId yet (the INVITE hasn't landed); LinphoneManager reconciles by
    // callId when IncomingReceived fires. CallKit dedupes on the reported UUID.
    let from = (payload.dictionaryPayload["from"] as? String) ?? "Incoming call"
    CallKitManager.shared.reportIncoming(callId: nil, handle: from)

    // Wake liblinphone so it can pick up the INVITE that follows over the SIP socket.
    LinphoneManager.shared.start()

    completion()
  }
}
