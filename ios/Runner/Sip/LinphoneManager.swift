import Foundation
import AVFoundation
import Network
import linphonesw   // module name from the official linphone-sdk pod

/// iOS-side singleton around liblinphone's Swift Core.
///
/// Notes:
/// * `Factory.shared.createCore` initialises the Core with default config paths.
/// * Event delegation uses `CoreDelegateStub` from linphonesw.
/// * Incoming calls are mirrored to CallKit via [CallKitManager] so the lock
///   screen shows the system ringer surface even if the app was killed.
final class LinphoneManager {

  static let shared = LinphoneManager()

  /// Emits state events to Dart. Payload is JSON-serialisable.
  var onEvent: (([String: Any?]) -> Void)?

  private let core: Core
  private var delegate: CoreDelegate?

  /// Pending registration watchdog — cancelled/rescheduled by
  /// verifyRegistration / softReconnect / the network monitor so only
  /// the most recent reconnect attempt owns the 5s fallback.
  private var watchdog: DispatchWorkItem?
  /// Debounced synthetic-Failed emit fired when the network drops for
  /// >2s, so a brief blip doesn't pause the agent on the box.
  private var offlineEmit: DispatchWorkItem?

  /// OS-level network reachability monitor (parity with Android's
  /// ConnectivityManager.NetworkCallback). Drives setNetworkReachable
  /// + auto-reconnect so recovery never requires the user to toggle
  /// the internet by hand.
  private let pathMonitor = NWPathMonitor()
  private let pathQueue = DispatchQueue(label: "io.vicifast.phone.sip.network")
  private var monitorStarted = false

  private init() {
    LoggingService.Instance.logLevel = .Message
    do {
      core = try Factory.Instance.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil)
      core.keepAliveEnabled = true
      // One call at a time: a second INVITE is answered 486 Busy, so VICIdial
      // routes it elsewhere instead of it replacing the call on screen.
      core.maxCalls = 1
      core.autoIterateEnabled = true
      core.ipv6Enabled = true
      core.videoCaptureEnabled = false
      core.videoDisplayEnabled = false
      core.pushNotificationEnabled = true  // we'll feed PushKit tokens into the Core

      // CallKit owns the AVAudioSession on iOS. With this flag the Core
      // stops auto-configuring/activating the session itself and instead
      // waits for us to hand it the CallKit-activated session via
      // activateAudioSession(actived:) from the CXProvider didActivate/
      // didDeactivate callbacks. Without it, an answered call has no
      // audio because liblinphone's stream starts against a session
      // CallKit hasn't yet activated (NAT-9).
      core.callkitEnabled = true

      // Audio codec preference for VICIdial / Asterisk: opus, then PCMU, PCMA. Disable rest.
      core.audioPayloadTypes.forEach { pt in
        let keep = ["opus", "PCMU", "PCMA"].contains(pt.mimeType)
        _ = try? pt.enable(enabled: keep)
      }

      // Silence liblinphone's incoming-call ringtone. CallKit plays
      // the system ringtone via the CXProvider when reportNewIncomingCall
      // lands; without this the user hears both at once — CallKit's
      // ring and liblinphone's internal player. Empty path disables
      // the built-in player; outbound ringback is left alone.
      core.ring = ""
    } catch {
      fatalError("Failed to initialise liblinphone Core: \(error)")
    }
    attachDelegate()
  }

  // MARK: Lifecycle

  func start() {
    try? core.start()
    startNetworkMonitor()
  }

  func stop() {
    core.stop()
  }

  // MARK: Registration

  enum SipError: Error { case invalidAddress }

  func register(username: String, password: String, domain: String,
                proxy: String?, transport: String, port: Int?) throws {
    core.clearAccounts()
    core.clearAllAuthInfo()

    let auth = try Factory.Instance.createAuthInfo(
      username: username, userid: nil, passwd: password,
      ha1: nil, realm: nil, domain: domain
    )
    core.addAuthInfo(info: auth)

    let identity = "sip:\(username)@\(domain)"
    guard let identityAddr = try? Factory.Instance.createAddress(addr: identity) else {
      throw SipError.invalidAddress
    }

    let serverAddrStr: String = {
      var s = "sip:\(proxy ?? domain)"
      if let port = port { s += ":\(port)" }
      s += ";transport=\(transport.lowercased())"
      return s
    }()
    guard let serverAddr = try? Factory.Instance.createAddress(addr: serverAddrStr) else {
      throw SipError.invalidAddress
    }
    let t: TransportType = {
      switch transport.lowercased() {
      case "tcp": return .Tcp
      case "tls": return .Tls
      default:    return .Udp
      }
    }()
    try? serverAddr.setTransport(newValue: t)

    let params = try core.createAccountParams()
    try params.setIdentityaddress(newValue: identityAddr)
    try params.setServeraddress(newValue: serverAddr)
    params.registerEnabled = true
    params.expires = 3600
    params.pushNotificationAllowed = true

    let account = try core.createAccount(params: params)
    try core.addAccount(account: account)
    core.defaultAccount = account
  }

  func unregister() {
    guard let acc = core.defaultAccount else { return }
    let p = acc.params?.clone()
    p?.registerEnabled = false
    if let p = p { try? acc.setParams(newValue: p) }
  }

  var registrationState: String {
    core.defaultAccount?.state.description ?? "None"
  }

  /// Hard-reconnect — re-adds the current default account from scratch,
  /// rebuilding the SIP socket and DNS resolution. Mirror of the Android
  /// `forceRefresh`. Used by the watchdog and the manual Reconnect.
  /// No-op if no account / no cached password.
  func forceRefresh() {
    // Re-arm reachability first. onNetworkLost sets networkReachable
    // false; if the OS never reports the path satisfied again after a
    // NAT idle timeout (vs. an interface change), the Core stays
    // unreachable and silently drops the REGISTER we're about to queue
    // — the user taps Reconnect and nothing goes on the wire. Forcing
    // it true here makes the manual Reconnect actually transmit.
    core.networkReachable = true
    guard let existing = core.defaultAccount,
          let params = existing.params,
          let identity = params.identityAddress else {
      NSLog("[Sip] forceRefresh — no account, skipping")
      return
    }
    let username = identity.username
    let domain = identity.domain
    guard !username.isEmpty, !domain.isEmpty else { return }
    // Account doesn't expose the password; peel it from the cached
    // AuthInfo addAuthInfo() stored at register() time.
    guard let pwd = core.authInfoList.first(where: { $0.username == username })?.passwd,
          !pwd.isEmpty else {
      NSLog("[Sip] forceRefresh — no cached password for \(username), skipping")
      return
    }
    let server = params.serverAddress
    let proxy = server?.domain
    let transport = server.map { String(describing: $0.transport).lowercased() } ?? "udp"
    let port: Int? = server.flatMap { $0.port > 0 ? Int($0.port) : nil }
    NSLog("[Sip] forceRefresh(\(username)@\(domain)) — clearing + re-adding account")
    core.clearAccounts()
    try? register(username: username, password: pwd, domain: domain,
                  proxy: proxy, transport: transport, port: port)
  }

  /// Cold-start / resume verification — always sends a fresh REGISTER
  /// round-trip regardless of the cached account state. Mirror of the
  /// Android `verifyRegistration`. A cached `.Ok` can lie after a long
  /// background (Core survived, UDP/NAT binding died), so this refreshes
  /// and arms a 5s watchdog that hard-reconnects if it doesn't land Ok.
  func verifyRegistration() {
    core.networkReachable = true
    if core.currentCall != nil {
      NSLog("[Sip] verifyRegistration deferred — call in progress")
      return
    }
    core.refreshRegisters()
    scheduleWatchdog()
  }

  /// Soft reconnect — refreshRegisters on the existing socket, with a
  /// watchdog fallback to forceRefresh. Mirror of the Android
  /// `softReconnect`. Short-circuits when already Ok so a routine
  /// resume doesn't generate a visible deregister+register on every
  /// unlock.
  func softReconnect() {
    core.networkReachable = true
    if core.currentCall != nil {
      NSLog("[Sip] softReconnect deferred — call in progress")
      return
    }
    if core.defaultAccount?.state == .Ok {
      NSLog("[Sip] softReconnect skipped — already registered")
      return
    }
    core.refreshRegisters()
    scheduleWatchdog()
  }

  /// Fully removes the SIP account + auth info from the Core. Mirror of
  /// the Android `wipeAccount`. Called on logout so the next launch
  /// doesn't see stale credentials still loaded. Call AFTER unregister
  /// so the Expires:0 REGISTER has a chance to land first.
  func wipeAccount() {
    watchdog?.cancel()
    offlineEmit?.cancel()
    core.clearAccounts()
    core.clearAllAuthInfo()
  }

  /// Arms (or re-arms) the 5s registration watchdog. Cancels any prior
  /// pending watchdog so only the latest reconnect attempt owns the
  /// fallback.
  private func scheduleWatchdog() {
    watchdog?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      guard let state = self.core.defaultAccount?.state else { return }
      if state != .Ok && self.core.currentCall == nil {
        NSLog("[Sip] watchdog: reg=\(state) after 5s, forcing hard reconnect")
        self.forceRefresh()
      }
    }
    watchdog = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
  }

  // MARK: Network monitor

  private func startNetworkMonitor() {
    guard !monitorStarted else { return }
    monitorStarted = true
    pathMonitor.pathUpdateHandler = { [weak self] path in
      // pathUpdateHandler fires on pathQueue — hop to main before
      // touching the Core (its API isn't thread-safe for callers).
      DispatchQueue.main.async {
        guard let self = self else { return }
        if path.status == .satisfied {
          self.onNetworkAvailable()
        } else {
          self.onNetworkLost()
        }
      }
    }
    pathMonitor.start(queue: pathQueue)
  }

  private func onNetworkAvailable() {
    NSLog("[Sip] network available — reconnect+watchdog")
    // Cancel any pending synthetic-Failed so a brief blip doesn't flip
    // the agent inactive on the box.
    offlineEmit?.cancel()
    core.networkReachable = true
    if core.currentCall != nil { return }
    // Skip the REGISTER refresh when already Ok — the path handler
    // re-fires on routine transitions even when the socket never died.
    if core.defaultAccount?.state == .Ok {
      NSLog("[Sip] reconnect skipped — already registered")
      return
    }
    core.refreshRegisters()
    scheduleWatchdog()
  }

  private func onNetworkLost() {
    NSLog("[Sip] network lost — marking SIP unreachable")
    core.networkReachable = false
    watchdog?.cancel()
    offlineEmit?.cancel()
    // Emit a synthetic regState=Failed after a 2s debounce so Dart's
    // _watchSipReg pauses the box (no server-side reachability poller
    // on deployed boxes). Skipped while a call is active.
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      if self.core.currentCall != nil {
        NSLog("[Sip] offline-emit skipped — call in progress")
        return
      }
      NSLog("[Sip] network offline >2s — emitting synthetic regState=Failed")
      self.onEvent?([
        "type": "regState",
        "state": "Failed",
        "message": "network unreachable"
      ])
    }
    offlineEmit = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
  }

  // MARK: Calls

  @discardableResult
  func placeCall(to: String) -> String? {
    guard let addr = core.interpretUrl(url: to, applyInternationalPrefix: false) else { return nil }
    guard let params = try? core.createCallParams(call: nil) else { return nil }
    let call = core.inviteAddressWithParams(addr: addr, params: params)
    let id = call?.callLog?.callId
    if let id = id {
      // Tell CallKit so the outgoing call appears in recents / Siri history
      CallKitManager.shared.reportOutgoing(callId: id, handle: to)
    }
    return id
  }

  func answer() {
    try? core.currentCall?.accept()
  }

  /// Hands CallKit's audio-session activation state to liblinphone. Called
  /// from the CXProvider didActivate/didDeactivate callbacks. When true,
  /// liblinphone routes its RTP media through the session CallKit just
  /// activated; when false it releases it on call teardown. Paired with
  /// `core.callkitEnabled = true` at init (NAT-9).
  func setAudioSessionActive(_ active: Bool) {
    core.activateAudioSession(actived: active)
  }

  func hangup() {
    // Single convergence point for ALL agent-initiated hangups — in-app
    // red button (via Dart bridge), pre-answer Decline, and the CallKit
    // End Call action (CXEndCallAction → CallKitManager → here). Mirrors
    // Android's LinphoneManager.hangup(). Caller-initiated BYEs never
    // enter this function; liblinphone's internal state machine fires the
    // regular callState=ended event but skips this signal.
    //
    // Emit the intent BEFORE terminate() so the EventChannel delivers it
    // to Dart ahead of the callState=ended event terminate() generates
    // (same channel, same thread, FIFO). AgentController._watchCallEnd
    // watches lastHangupIntentAt to attribute the dispo as hangup_by=agent.
    onEvent?(["type": "agentInitiatedHangup"])
    if let c = core.currentCall {
      try? c.terminate()
    } else {
      try? core.terminateAllCalls()
    }
  }

  func sendDtmf(_ digit: Character) {
    try? core.currentCall?.sendDtmf(dtmf: digit.asciiValue.map(CChar.init) ?? 0)
  }

  func setMute(_ muted: Bool) {
    core.micEnabled = !muted
  }

  func setHold(_ on: Bool) {
    // core.currentCall is nil while the call is paused, so resuming needs the
    // fallback to core.calls (the Android twin does the same).
    guard let c = core.currentCall ?? core.calls.first else {
      NSLog("[Sip] setHold(\(on)) ignored — no call")
      return
    }
    do {
      if on { try c.pause() } else { try c.resume() }
    } catch {
      // Don't swallow — without surfacing this the UI gets stuck
      // showing "Hold" while the call is actually still paused,
      // or vice versa. The Dart bridge will see the thrown method
      // call and emit a hold-failed event.
      NSLog("[Sip] setHold(\(on)) failed: \(error)")
    }
  }

  func setSpeaker(_ on: Bool) {
    let route: AVAudioSession.PortOverride = on ? .speaker : .none
    try? AVAudioSession.sharedInstance().overrideOutputAudioPort(route)
  }

  func currentCallSnapshot() -> [String: Any?]? {
    guard let c = core.currentCall else { return nil }
    return snapshot(c)
  }

  // MARK: Delegate

  private func attachDelegate() {
    let d = CoreDelegateStub(
      onCallStateChanged: { [weak self] _, call, state, message in
        guard let self = self else { return }
        let snap = self.snapshot(call)
        self.onEvent?([
          "type": "callState",
          "state": String(describing: state),
          "message": message,
          "call": snap
        ])
        let callId = call.callLog?.callId
        switch state {
        case .IncomingReceived:
          // Mirror to CallKit so the lock-screen ringer shows up. CallKit
          // owns the UUID keyed on liblinphone's callId so every later
          // action (answer/end) targets the SAME UUID (NAT-7).
          let from = call.remoteAddress?.displayName.isEmpty == false
            ? call.remoteAddress?.displayName ?? "Unknown"
            : (call.remoteAddress?.username ?? "Unknown")
          CallKitManager.shared.reportIncoming(callId: callId, handle: from)
        case .OutgoingProgress, .OutgoingRinging, .OutgoingEarlyMedia:
          if let callId = callId {
            CallKitManager.shared.reportOutgoingConnecting(callId: callId)
          }
        case .Connected, .StreamsRunning:
          if let callId = callId {
            // Advances an OUTGOING CallKit call to connected so its timer
            // starts. No-op for incoming calls (CallKitManager gates this to
            // UUIDs created via CXStartCallAction); incoming calls go
            // connected automatically when CXAnswerCallAction is fulfilled.
            CallKitManager.shared.reportOutgoingConnected(callId: callId)
          }
        case .End, .Released, .Error:
          // The call already ended in liblinphone (remote BYE, error, or the
          // tail of an agent hangup). Inform CallKit of the natural end via
          // reportCall(endedAt:) — NOT endCall(), which would issue a fresh
          // CXEndCallAction and re-enter LinphoneManager.hangup(),
          // mis-emitting agentInitiatedHangup for a remote hangup (NAT-11).
          if let callId = callId {
            CallKitManager.shared.reportEnded(callId: callId)
          }
          // Mute and the speaker route outlive the call; reset them once no
          // call is left so the next one starts unmuted on the receiver.
          if self.core.callsNb == 0 {
            self.core.micEnabled = true
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
          }
        default: break
        }
      },
      onAccountRegistrationStateChanged: { [weak self] _, _, state, message in
        self?.onEvent?([
          "type": "regState",
          "state": String(describing: state),
          "message": message
        ])
      }
    )
    core.addDelegate(delegate: d)
    self.delegate = d
  }

  private func snapshot(_ call: Call) -> [String: Any?] {
    return [
      "callId": call.callLog?.callId,
      "remoteUri": call.remoteAddress?.asStringUriOnly(),
      "remoteDisplay": (call.remoteAddress?.displayName.isEmpty == false)
        ? call.remoteAddress?.displayName
        : call.remoteAddress?.username,
      "direction": call.dir == .Incoming ? "incoming" : "outgoing",
      "state": String(describing: call.state),
      "durationSec": call.duration
    ]
  }

  // MARK: PushKit token wiring (called from PushKitManager)

  /// PushKit hands the token over once, at launch — usually before Dart is
  /// listening. Kept so the plugin can replay it when Dart subscribes.
  private(set) var lastVoipToken: String?

  func clearVoipPushToken() {
    lastVoipToken = nil
  }

  func setVoipPushToken(_ tokenHex: String) {
    lastVoipToken = tokenHex
    // Feed the real APNs VoIP token to liblinphone so REGISTER carries a
    // valid pn-prid alongside the pn-provider / pn-param push params
    // (RFC 8599). Without a real token the pn-* params reference nothing
    // and the push gateway can't wake the device (NAT-8). The Core then
    // appends the Contact push params on its own REGISTERs. The ":voip"
    // suffix marks this as the PushKit token in liblinphone's expected
    // stringified form.
    core.didRegisterForRemotePushWithStringifiedToken(deviceTokenStr: "\(tokenHex):voip")
    // Also forward up to Dart so it can POST the token to the provisioning
    // backend (server-side push-wake plumbing is owned by a sibling branch).
    onEvent?(["type": "voipToken", "token": tokenHex, "platform": "apns"])
  }
}
