import Foundation
import CallKit
import AVFoundation

/// Drives the iOS CallKit incoming/outgoing call UI.
///
/// CallKit is *the* path to a lock-screen ringer on iOS — there is no other
/// supported way to surface incoming VoIP calls when the device is locked.
/// Apple requires that every VoIP push (PushKit) reports an incoming call to
/// CallKit before the app returns from `didReceiveIncomingPushWith`.
final class CallKitManager: NSObject {

  static let shared = CallKitManager()

  private let provider: CXProvider
  private let controller = CXCallController()

  /// Maps liblinphone callId <-> CallKit UUID so we can correlate user actions
  /// and, crucially, end/report the SAME UUID CallKit was created with. A
  /// mismatched UUID makes CXEndCallAction a no-op and the system call UI
  /// sticks forever (NAT-7).
  private var uuidByCallId: [String: UUID] = [:]
  private var callIdByUuid: [UUID: String] = [:]

  /// UUID reported to CallKit from a VoIP push before the SIP INVITE (and thus
  /// the liblinphone callId) exists. Reconciled to the real callId when
  /// IncomingReceived fires, so the whole call keeps ONE UUID (NAT-7).
  private var pendingPushUuid: UUID?

  /// UUIDs created via CXStartCallAction (outgoing). Only these accept
  /// reportOutgoingCall(_:startedConnectingAt:/connectedAt:); calling it on an
  /// incoming UUID is an API misuse — incoming calls transition to connected
  /// automatically when CXAnswerCallAction is fulfilled.
  private var outgoingUuids: Set<UUID> = []

  override init() {
    let config = CXProviderConfiguration()
    config.supportsVideo = false
    config.supportedHandleTypes = [.generic, .phoneNumber]
    config.maximumCallsPerCallGroup = 1
    config.maximumCallGroups = 1
    config.includesCallsInRecents = true
    config.iconTemplateImageData = nil   // TODO: set a 40x40 mask image
    if let ringtone = Bundle.main.path(forResource: "ringtone", ofType: "caf") {
      config.ringtoneSound = ringtone
    }
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  // MARK: UUID <-> callId bookkeeping

  private func uuid(for callId: String) -> UUID {
    if let existing = uuidByCallId[callId] { return existing }
    let uuid = UUID()
    uuidByCallId[callId] = uuid
    callIdByUuid[uuid] = callId
    return uuid
  }

  private func forget(uuid: UUID) {
    if let callId = callIdByUuid.removeValue(forKey: uuid) {
      uuidByCallId.removeValue(forKey: callId)
    }
    if pendingPushUuid == uuid { pendingPushUuid = nil }
    outgoingUuids.remove(uuid)
  }

  // MARK: Incoming (called from PushKit and from LinphoneManager)

  /// Reports an incoming call and returns the UUID CallKit now owns for it.
  ///
  /// PushKit calls this with callId == nil (the INVITE hasn't landed) and we
  /// stash the UUID. When liblinphone later fires IncomingReceived it calls
  /// again WITH the callId; we reuse the stashed UUID and only bind it to the
  /// callId — never a second reportNewIncomingCall for the same call, which
  /// would surface a duplicate ringer and leave the push UUID dangling (NAT-7).
  @discardableResult
  func reportIncoming(callId: String?, handle: String) -> UUID {
    let uuid: UUID
    if let callId = callId {
      // Reconcile: if a push already reported an incoming UUID, adopt it for
      // this callId instead of minting a new one (and skip re-reporting).
      if let pending = pendingPushUuid {
        pendingPushUuid = nil
        uuidByCallId[callId] = pending
        callIdByUuid[pending] = callId
        return pending
      }
      if let existing = uuidByCallId[callId] { return existing }
      uuid = self.uuid(for: callId)
    } else {
      uuid = UUID()
      pendingPushUuid = uuid
    }

    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: handle)
    update.hasVideo = false
    update.localizedCallerName = handle
    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error = error {
        NSLog("CallKit reportNewIncomingCall failed: \(error)")
      }
    }
    return uuid
  }

  func reportOutgoing(callId: String, handle: String) {
    let uuid = self.uuid(for: callId)
    outgoingUuids.insert(uuid)
    let handleObj = CXHandle(type: .generic, value: handle)
    let action = CXStartCallAction(call: uuid, handle: handleObj)
    let tx = CXTransaction(action: action)
    controller.request(tx) { error in
      if let error = error {
        NSLog("CallKit start outgoing failed: \(error)")
      }
    }
  }

  /// liblinphone state -> CallKit outgoing lifecycle. Called from the Core
  /// delegate so the system UI advances from "calling" to "connected" and
  /// the timer starts. Without these, an outgoing CallKit call is stuck in
  /// the dialing state and CXStartCallAction is never satisfied (NAT-16).
  func reportOutgoingConnecting(callId: String) {
    guard let uuid = uuidByCallId[callId], outgoingUuids.contains(uuid) else { return }
    provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
  }

  func reportOutgoingConnected(callId: String) {
    guard let uuid = uuidByCallId[callId], outgoingUuids.contains(uuid) else { return }
    provider.reportOutgoingCall(with: uuid, connectedAt: Date())
  }

  /// Tells CallKit a call ended on its own (remote BYE, error) so the system
  /// UI tears down. Uses the SAME UUID the call was created with (NAT-7).
  func reportEnded(callId: String, reason: CXCallEndedReason = .remoteEnded) {
    guard let uuid = uuidByCallId[callId] else { return }
    provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    forget(uuid: uuid)
  }

  func endCall(uuid: UUID) {
    let action = CXEndCallAction(call: uuid)
    controller.request(CXTransaction(action: action)) { error in
      if let error = error {
        NSLog("CallKit end call failed: \(error)")
      }
    }
  }
}

extension CallKitManager: CXProviderDelegate {

  func providerDidReset(_ provider: CXProvider) {
    LinphoneManager.shared.hangup()
    uuidByCallId.removeAll()
    callIdByUuid.removeAll()
    pendingPushUuid = nil
    outgoingUuids.removeAll()
  }

  /// Fulfilling the start action is mandatory — without it CallKit leaves the
  /// outgoing call pending, the "calling" UI hangs, and subsequent transactions
  /// for that call fail. We also report startedConnecting immediately so the
  /// system UI reflects that dialing has begun (NAT-16).
  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    configureAudioSession()
    LinphoneManager.shared.answer()
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    LinphoneManager.shared.hangup()
    forget(uuid: action.callUUID)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    LinphoneManager.shared.setMute(action.isMuted)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    LinphoneManager.shared.setHold(action.isOnHold)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    if let d = action.digits.first { LinphoneManager.shared.sendDtmf(d) }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    // Hand the CallKit-activated AVAudioSession to liblinphone. CallKit has
    // already activated the session; we must NOT re-activate it ourselves.
    // The Core is configured with callkitEnabled = true, so it does not touch
    // the session on its own and waits for this hand-off before starting
    // media — otherwise an answered call has no audio (NAT-9).
    LinphoneManager.shared.setAudioSessionActive(true)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    // Release the session back to liblinphone so it tears down its streams
    // against the now-deactivated session (NAT-9).
    LinphoneManager.shared.setAudioSessionActive(false)
  }

  private func configureAudioSession() {
    let s = AVAudioSession.sharedInstance()
    try? s.setCategory(.playAndRecord,
                       mode: .voiceChat,
                       options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
    try? s.setPreferredSampleRate(48000)
    try? s.setPreferredIOBufferDuration(0.02)
  }
}
