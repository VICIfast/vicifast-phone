package io.vicifast.vicifast_phone.sip

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.linphone.core.Account
import org.linphone.core.AccountParams
import org.linphone.core.AudioDevice
import org.linphone.core.AuthInfo
import org.linphone.core.Call
import org.linphone.core.Core
import org.linphone.core.CoreListenerStub
import org.linphone.core.Factory
import org.linphone.core.RegistrationState
import org.linphone.core.TransportType

/**
 * Singleton wrapper around liblinphone Core.
 *
 * Lifecycle:
 *  - [getInstance] lazily creates Core via Factory
 *  - [start] iterates the Core scheduler on a 20ms timer (required by liblinphone)
 *  - [register] applies SIP account params and starts REGISTER
 *  - on incoming call -> emits "incoming" event AND starts foreground service +
 *    routes to ConnectionService so the lock-screen ringer shows up
 *
 * Events emitted to Dart via [onEvent]: a Map<String,Any?> with at least {"type": ...}.
 */
class LinphoneManager private constructor(private val appContext: Context) {

    companion object {
        private const val TAG = "Linphone"
        private const val RETRY_MIN_MS = 5_000L
        private const val RETRY_MAX_MS = 60_000L
        @Volatile private var INSTANCE: LinphoneManager? = null
        fun getInstance(ctx: Context): LinphoneManager =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: LinphoneManager(ctx.applicationContext).also { INSTANCE = it }
            }
    }

    var onEvent: ((Map<String, Any?>) -> Unit)? = null

    private val core: Core = Factory.instance().createCore(null, null, appContext).apply {
        // VICIdial / Asterisk friendly defaults
        isKeepAliveEnabled = true
        // One call at a time: a second INVITE is answered 486 Busy, so VICIdial
        // routes it elsewhere instead of it replacing the call on screen.
        maxCalls = 1
        isPushNotificationEnabled = false  // we drive Core ourselves via FCM
        isAutoIterateEnabled = true        // Core schedules its own iterate()
        isIpv6Enabled = true
        isVideoCaptureEnabled = false
        isVideoDisplayEnabled = false
        // Send DTMF via both RFC2833 (telephone-event) and SIP INFO so IVRs
        // expecting either path receive digits reliably.
        useRfc2833ForDtmf = true
        useInfoForDtmf = true
        // Prefer Opus + PCMU/PCMA — VICIdial commonly uses ulaw/alaw
        // Codec ordering: opus (wideband), then pcmu, pcma; everything else off.
        audioPayloadTypes.forEach { it.enable(it.mimeType in setOf("opus", "PCMU", "PCMA")) }

        // Silence liblinphone's incoming-call ringtone. Android Telecom
        // (SipConnectionService.setRinging() → CallStyle notification +
        // system ringtone) already handles the ring; without this the
        // user hears two simultaneous ringtones — the OS one and
        // liblinphone's internal player. Empty path disables the
        // built-in player without affecting outbound ringback (which
        // we still want — there's no system equivalent for that).
        ring = ""
    }

    private val listener = object : CoreListenerStub() {
        override fun onAccountRegistrationStateChanged(
            core: Core,
            account: Account,
            state: RegistrationState,
            message: String
        ) {
            Log.i(TAG, "regState=$state msg=$message")
            onEvent?.invoke(mapOf(
                "type" to "regState",
                "state" to state.name,
                "message" to message
            ))

            when (state) {
                RegistrationState.Ok -> {
                    // Remember which network this registration is bound to
                    // so the network monitor can tell a genuine handoff
                    // (wifi→cell: must re-register even though the account
                    // still reads Ok on the dead socket) from a false-alarm
                    // onAvailable (screen unlock: skip, stay quiet).
                    boundNetwork = cm.activeNetwork
                    retryDelayMs = RETRY_MIN_MS
                    mainHandler.removeCallbacksAndMessages(retryToken)
                }
                RegistrationState.Failed -> scheduleRegistrationRetry()
                RegistrationState.Cleared,
                RegistrationState.None -> {
                    boundNetwork = null
                    retryDelayMs = RETRY_MIN_MS
                    mainHandler.removeCallbacksAndMessages(retryToken)
                }
                else -> {}
            }

            // Keep the SIP socket alive across Doze + screen lock by holding
            // a low-importance foreground service whenever an account is
            // registered. We don't touch the FGS while a call is in progress
            // — the in-call mode takes priority and is managed below.
            if (core.currentCall != null) return
            when (state) {
                RegistrationState.Ok -> startRegisteredForegroundService(account)
                RegistrationState.Cleared,
                RegistrationState.None -> SipForegroundService.stop(appContext)
                else -> {}
            }
        }

        override fun onCallStateChanged(
            core: Core,
            call: Call,
            state: Call.State,
            message: String
        ) {
            Log.i(TAG, "callState=$state msg=$message remote=${call.remoteAddress.asStringUriOnly()}")
            val callMap = callSnapshot(call)
            onEvent?.invoke(mapOf(
                "type" to "callState",
                "state" to state.name,
                "message" to message,
                "call" to callMap
            ))

            val peer = peerDisplayLabel(call)
            when (state) {
                Call.State.IncomingReceived -> {
                    // Wake the device, show ConnectionService incoming call UI
                    SipConnectionService.reportIncoming(
                        appContext,
                        callId = call.callLog.callId ?: System.currentTimeMillis().toString(),
                        from = peer
                    )
                    // DO NOT switch the FGS to in-call mode here. The
                    // in-call mode posts a CallStyle.forOngoingCall
                    // notification with a chronometer that starts
                    // counting from now() — so an unanswered ringing
                    // call would surface on the lock screen as
                    // "Active call · 00:42" alongside the actual
                    // Answer/Decline notification, and most OEM
                    // shades render the ongoing-call one in
                    // preference. The mic isn't opened until the
                    // call is Connected, so REGISTERED mode (DATA_SYNC
                    // FGS, silent idle notification) is enough during
                    // the ringing window. Switch happens below at
                    // Connected/StreamsRunning.
                }
                Call.State.OutgoingInit,
                Call.State.OutgoingProgress,
                Call.State.OutgoingRinging,
                Call.State.OutgoingEarlyMedia -> {
                    startForegroundService(peer)
                }
                Call.State.Connected,
                Call.State.StreamsRunning -> {
                    // Bridge to Telecom: stops the OS ringer + vibration the
                    // moment the call is answered (whether the user tapped
                    // Answer on the native ringer UI or in our in-app
                    // IncomingCallScreen). Without this, the Connection
                    // stays in STATE_RINGING and keeps vibrating until the
                    // call ends.
                    SipConnectionService.setActive(appContext)
                    startForegroundService(peer)
                }
                Call.State.Paused,
                Call.State.Pausing -> {
                    SipConnectionService.setOnHold(appContext, held = true)
                    startForegroundService(peer)
                }
                Call.State.PausedByRemote -> {
                    SipConnectionService.setOnHold(appContext, held = true)
                    startForegroundService(peer)
                }
                Call.State.Resuming -> {
                    SipConnectionService.setOnHold(appContext, held = false)
                    startForegroundService(peer)
                }
                Call.State.End,
                Call.State.Released,
                Call.State.Error -> {
                    // Dismiss the Telecom Connection — this is what stops
                    // the lock-screen notification and any residual ringer
                    // vibration. Self-managed connections are NOT auto-
                    // cleaned by the platform; without this they linger
                    // forever (the original bug).
                    SipConnectionService.endCall(appContext)
                    // Mute and the speaker are Core-wide, not per call. Reset
                    // them once no call is left, so the next call doesn't start
                    // muted or on the speaker while the app shows both off.
                    if (core.callsNb == 0) {
                        core.isMicEnabled = true
                        if (core.outputAudioDevice?.type == AudioDevice.Type.Speaker) {
                            core.outputAudioDevice = core.defaultOutputAudioDevice
                        }
                    }
                    // Revert to idle keep-alive so the registration stays
                    // alive once the call ends. If no account is registered
                    // any more, shut the FGS down entirely.
                    val acc = core.defaultAccount
                    if (acc != null && acc.state == RegistrationState.Ok) {
                        startRegisteredForegroundService(acc)
                    } else {
                        stopForegroundService()
                    }
                    if (pendingNetworkChangeRefresh) {
                        pendingNetworkChangeRefresh = false
                        Log.i(TAG, "call ended with pending network-change refresh — forcing re-register")
                        try { forceRefresh() } catch (t: Throwable) {
                            Log.w(TAG, "forceRefresh failed: ${t.message}")
                        }
                    }
                }
                else -> {}
            }
        }
    }

    init {
        core.addListener(listener)
    }

    // ---- Network reachability ---------------------------------------------
    //
    // liblinphone's built-in reachability check only fires on Core's own
    // iterate loop and reacts slowly to brief network drops. On mobile,
    // a WiFi→cellular handoff, captive-portal reauth, or a 5-second
    // packet drop can leave the UDP NAT binding dead while Core thinks
    // it's still registered. The next inbound INVITE silently fails, and
    // the agent sees "offline" only when liblinphone's next OPTIONS/
    // REGISTER fires (up to 2 minutes later).
    //
    // We hook Android's ConnectivityManager NetworkCallback so the
    // moment the OS sees a network change, we tell Core to drop
    // reachability and immediately refresh the REGISTER. The race
    // between "carrier handoff" and "agent gets call" goes from
    // ~2 minutes to ~2 seconds.

    private val cm by lazy {
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val watchdogToken = Any()

    /**
     * The default network the current registration was established on
     * (captured at every regState=Ok). When onAvailable reports a
     * DIFFERENT network, the old socket is bound to a dead interface —
     * liblinphone still reads Ok on it, so the skip-if-Ok reconnect
     * guard must be bypassed. Null while unregistered.
     */
    private var boundNetwork: Network? = null

    /**
     * Set when the default network changes while a call is active —
     * clearAccounts mid-call would tear down the call's signaling, so
     * the rebuild is deferred to the call's End/Released/Error handler.
     */
    private var pendingNetworkChangeRefresh = false

    /**
     * Registration-failure retry loop. liblinphone gives up on its own
     * schedule after a REGISTER failure; without this the agent stays
     * Failed until they manually reconnect or toggle the internet.
     * Backoff doubles RETRY_MIN_MS→RETRY_MAX_MS per consecutive
     * failure, resets on Ok, cancels on Cleared/None (logout) and
     * while no network is available (onAvailable re-arms via its
     * reconnect path). Retries forever — availability policy is
     * "registered while logged in + online", with no time limit.
     */
    private val retryToken = Any()
    private var retryDelayMs = RETRY_MIN_MS

    private fun scheduleRegistrationRetry() {
        if (cm.activeNetwork == null) {
            Log.i(TAG, "registration retry skipped — no network available")
            return
        }
        val delay = retryDelayMs
        retryDelayMs = (retryDelayMs * 2).coerceAtMost(RETRY_MAX_MS)
        Log.i(TAG, "registration Failed — retrying in ${delay / 1000}s")
        mainHandler.removeCallbacksAndMessages(retryToken)
        mainHandler.postDelayed({
            val state = core.defaultAccount?.state ?: return@postDelayed
            if (state != RegistrationState.Failed) return@postDelayed
            if (core.currentCall != null) {
                // Can't REGISTER mid-call; re-check after the same delay.
                scheduleRegistrationRetry()
                return@postDelayed
            }
            triggerReconnectWithWatchdog(force = true)
        }, retryToken, delay)
    }

    /**
     * Token for the debounced synthetic regState=Failed runnable. Fires
     * 2s after `onLost` to give Dart a visible state transition for the
     * `_watchSipReg` pause-on-box path — liblinphone's own
     * setNetworkReachable(false) only suspends Core's IO and doesn't
     * change the account state, and with expires=3600 the natural
     * REGISTER-fail transition is up to an hour away.
     *
     * 2s debounce so brief wifi/cellular handoffs don't flicker
     * pause→activate. Cancelled by onAvailable / onCapabilitiesChanged.
     * Also skipped if a call is active — we don't pause-on-box
     * mid-call for a network blip.
     */
    private val offlineEmitToken = Any()

    /**
     * Two-phase reconnect: immediate `refreshRegisters()` (cheap — just
     * sends a REGISTER on the existing socket), then a 5s watchdog that
     * runs `forceRefresh()` if the registration didn't reach Ok in
     * time. This catches the dead-UDP-binding case where the carrier
     * NAT has expired the mapping but liblinphone's socket is still
     * "open" from its perspective — refreshRegisters writes into the
     * void and waits ~30s before declaring failure.
     *
     * setNetworkReachable(true) is ALWAYS run — even mid-call — so
     * RTP can resume the instant the network is back. Without that
     * unconditional call, a brief drop during a call leaves Core in
     * "unreachable" mode after recovery, RTP stays frozen, and the
     * agent + customer hear silence until Asterisk RTP-timeout
     * (~30s) tears the call down.
     *
     * The REGISTER refresh + watchdog gate is what's call-guarded:
     * sending a fresh REGISTER mid-call can make Asterisk
     * re-dispatch the contact, disrupting active audio. Deferred
     * until the call ends.
     */
    /**
     * Public wrapper for the soft-reconnect-with-fallback path.
     * Tries `refreshRegisters()` (REGISTER refresh on the existing
     * socket — no clearAccounts) first; if reg isn't Ok after 5s,
     * the watchdog calls `forceRefresh()` to rebuild from scratch.
     *
     * Dart's `didChangeAppLifecycleState.resumed` uses this so a
     * screen unlock doesn't always do a hard reconnect (which
     * generates a visible REGISTER Expires:0 + REGISTER pair on the
     * wire). Most of the time `refreshRegisters` alone is enough;
     * the watchdog catches the dead-binding case.
     */
    fun softReconnect() {
        triggerReconnectWithWatchdog()
    }

    /**
     * Cold-start verification — ALWAYS sends a refreshRegisters()
     * regardless of liblinphone's cached account state, with the same
     * 5s watchdog → forceRefresh fallback.
     *
     * Dart's `_init()` uses this when the native side reports the
     * account as already Ok on cold start. The cached state may be
     * stale: the foreground service kept liblinphone "alive" through
     * the activity-killed window, but the UDP binding could have died
     * (carrier NAT expired, wifi handover, doze killed the socket).
     * Without an unconditional verify, the UI shows green-Connected
     * while the customer's box has already marked the phone as
     * deregistered — agent sees "Ready" but no calls come through;
     * the only recovery without this fix is reconnecting wifi or
     * re-logging in.
     *
     * Differs from [softReconnect] which short-circuits when the
     * cached state is Ok (an optimization that's correct for the
     * resume-from-unlock case, wrong for cold start).
     */
    fun verifyRegistration() {
        core.setNetworkReachable(true)
        if (core.currentCall != null) {
            Log.i(TAG, "verifyRegistration deferred — call in progress")
            return
        }
        core.refreshRegisters()
        mainHandler.removeCallbacksAndMessages(watchdogToken)
        mainHandler.postDelayed({
            val state = core.defaultAccount?.state
            if (state == null) return@postDelayed
            if (state != RegistrationState.Ok && core.currentCall == null) {
                Log.i(TAG, "verifyRegistration watchdog: reg=$state after 5s, forcing hard reconnect")
                try { forceRefresh() } catch (t: Throwable) {
                    Log.w(TAG, "forceRefresh failed: ${t.message}")
                }
            }
        }, watchdogToken, 5_000L)
    }

    private fun triggerReconnectWithWatchdog(force: Boolean = false) {
        core.setNetworkReachable(true)
        if (core.currentCall != null) {
            Log.i(TAG, "reconnect — RTP unfrozen; REGISTER refresh deferred (call in progress)")
            return
        }
        // Skip the REGISTER refresh + watchdog when we're already
        // registered. NetworkCallback.onAvailable fires on most
        // screen-unlock events (the OS re-emits network state even
        // when wifi never actually dropped, because the FGS kept
        // the socket alive through the lock window). Without this
        // guard, every unlock generates a visible REGISTER on the
        // wire and a brief reg-state flicker — agents perceived it
        // as "the app reconnects every time I unlock." The
        // Doze-killed-the-socket case still works: when the binding
        // is genuinely dead, defaultAccount.state will be Failed /
        // None / Cleared, this check skips, refreshRegisters runs,
        // and the watchdog forces a hard reconnect if needed.
        //
        // `force` bypasses the skip: after a default-network change
        // (wifi→cell) the account still reads Ok on a socket bound to
        // the dead interface — the one case where "already registered"
        // is a lie. Also used by the Failed-retry loop.
        val currentState = core.defaultAccount?.state
        if (!force && currentState == RegistrationState.Ok) {
            Log.i(TAG, "reconnect skipped — already registered (likely false-alarm onAvailable)")
            return
        }
        core.refreshRegisters()
        mainHandler.removeCallbacksAndMessages(watchdogToken)
        mainHandler.postDelayed({
            val state = core.defaultAccount?.state
            // Skip when there's no account yet (cold start, before
            // Dart layer has called register()) — nothing to reconnect.
            // Without this guard the watchdog logs "forcing hard
            // reconnect" with reg=null at every app launch.
            if (state == null) return@postDelayed
            if (state != RegistrationState.Ok && core.currentCall == null) {
                Log.i(TAG, "watchdog: reg=$state after 5s, forcing hard reconnect")
                try { forceRefresh() } catch (t: Throwable) {
                    Log.w(TAG, "forceRefresh failed: ${t.message}")
                }
            }
        }, watchdogToken, 5_000L)
    }

    private fun startNetworkMonitor() {
        if (networkCallback != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Network recovered — cancel any pending synthetic
                // Failed event so brief blips don't flip the agent
                // to inactive on the box.
                mainHandler.removeCallbacksAndMessages(offlineEmitToken)
                val changed = boundNetwork != null && network != boundNetwork
                if (!changed) {
                    Log.i(TAG, "network onAvailable — reconnect+watchdog")
                    triggerReconnectWithWatchdog()
                    return
                }
                // Default network CHANGED under an established
                // registration (wifi→cell handoff, or any reconnect
                // after an offline gap — a fresh connection is always a
                // new Network object). The account may still read Ok,
                // but its socket is bound to the OLD interface; during
                // make-before-break a refreshRegisters() can even
                // "succeed" over the dying wifi, leaving the box
                // contact pointing at a corpse. Only a full account
                // rebuild deterministically binds the new socket on the
                // new default route. This was the "shows Active/Ready
                // but never re-registers until I toggle the internet"
                // bug: the skip-if-Ok guard in the reconnect path
                // swallowed the one onAvailable that mattered.
                mainHandler.removeCallbacksAndMessages(retryToken)
                mainHandler.removeCallbacksAndMessages(watchdogToken)
                if (core.currentCall != null) {
                    // Don't clearAccounts mid-call — unfreeze RTP now,
                    // rebuild the registration when the call ends.
                    Log.i(TAG, "default network changed mid-call — re-register deferred")
                    core.setNetworkReachable(true)
                    pendingNetworkChangeRefresh = true
                    return
                }
                Log.i(TAG, "default network changed — forcing re-register on new network")
                try { forceRefresh() } catch (t: Throwable) {
                    Log.w(TAG, "forceRefresh failed: ${t.message}")
                }
            }
            override fun onLost(network: Network) {
                Log.i(TAG, "network onLost — marking SIP unreachable")
                core.setNetworkReachable(false)
                mainHandler.removeCallbacksAndMessages(watchdogToken)
                // Emit a synthetic regState=Failed event after a 2s
                // debounce. Drives Dart's _watchSipReg pause-on-box
                // path — without this the dialer keeps dispatching
                // calls to a dead phone (deployed boxes don't have a
                // SIP-reachability polling agent to do this server-
                // side, despite the assumption made in v0.1.35).
                // Skipped while a call is active — we don't want to
                // pause-on-box mid-call from a brief network blip.
                mainHandler.removeCallbacksAndMessages(offlineEmitToken)
                mainHandler.postDelayed({
                    if (core.currentCall != null) {
                        Log.i(TAG, "offline-emit skipped — call in progress")
                        return@postDelayed
                    }
                    Log.i(TAG, "network offline >2s — emitting synthetic regState=Failed")
                    onEvent?.invoke(mapOf(
                        "type" to "regState",
                        "state" to "Failed",
                        "message" to "network unreachable"
                    ))
                }, offlineEmitToken, 2_000L)
            }
            override fun onCapabilitiesChanged(
                network: Network,
                caps: NetworkCapabilities
            ) {
                // Captive-portal reauth or carrier handoff often only
                // surfaces as a capabilities change (VALIDATED flips).
                // Treat regaining INTERNET capability as a reconnect
                // trigger.
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
                    mainHandler.removeCallbacksAndMessages(offlineEmitToken)
                    triggerReconnectWithWatchdog()
                }
            }
        }
        try {
            // DEFAULT-network callback, not a request-based one: it fires
            // onAvailable on EVERY default-route change (the request-based
            // callback reports each matching network only once, so a
            // make-before-break wifi→cell handoff where cellular was
            // already up produced NO event and the dead binding was never
            // rebuilt). It also stops false offline emits when a
            // non-default network drops while the default is healthy.
            // liblinphone binds its sockets on the default route, so the
            // default network is exactly "the network the registration
            // lives on".
            //
            // Registered with mainHandler so EVERY callback (onAvailable /
            // onLost / onCapabilitiesChanged) is dispatched on the main
            // thread — the same thread the Core was created on and
            // auto-iterates on. Without a handler these arrive on an
            // arbitrary ConnectivityManager binder thread, and the
            // core.setNetworkReachable / refreshRegisters / forceRefresh
            // calls inside them would touch liblinphone Core off its
            // thread (intermittent no-op / crash). The (callback, handler)
            // overload is API 26+, which matches our minSdk.
            cm.registerDefaultNetworkCallback(cb, mainHandler)
            networkCallback = cb
        } catch (e: Exception) {
            Log.w(TAG, "registerDefaultNetworkCallback failed: ${e.message}")
        }
    }

    private fun stopNetworkMonitor() {
        networkCallback?.let {
            try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {}
            networkCallback = null
        }
        mainHandler.removeCallbacksAndMessages(retryToken)
        retryDelayMs = RETRY_MIN_MS
        pendingNetworkChangeRefresh = false
    }

    // ---- Lifecycle ---------------------------------------------------------

    /**
     * Run [block] on the thread the Core lives on. The Core is created on
     * the main thread (MainActivity.onCreate / SipPlugin.onAttachedToEngine)
     * and auto-iterates there, so `mainHandler` IS the core thread. Callers
     * that arrive on some other thread (e.g. the FCM background thread in
     * VoipFcmService) MUST route Core touches through here — touching Core
     * off its thread is an intermittent no-op / crash. Already-on-main
     * callers run [block] inline (no post) so a caller that needs the Core
     * touched synchronously — e.g. right before returning a snapshot — still
     * gets that ordering.
     */
    fun runOnCoreThread(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }

    fun start() {
        if (core.isAutoIterateEnabled.not()) core.isAutoIterateEnabled = true
        core.start()
        startNetworkMonitor()
    }

    fun stop() {
        stopNetworkMonitor()
        core.stop()
    }

    // ---- Registration ------------------------------------------------------

    fun register(
        username: String,
        password: String,
        domain: String,
        proxy: String?,
        transport: String,
        port: Int?
    ) {
        // Idempotency: if the same identity is already registered, this is a
        // no-op. Without this guard, activity recreation (which spins up a
        // new Flutter engine and re-runs SipController._init) would call
        // clearAccounts() and trigger an unregister+register pair on every
        // resume — the PBX sees it as a churn.
        val existing = core.defaultAccount
        if (existing != null && existing.state == RegistrationState.Ok) {
            val id = existing.params.identityAddress
            if (id?.username == username && id.domain == domain) {
                if (core.currentCall != null) {
                    // Mid-call: the live media path proves the SIP binding
                    // is alive end-to-end, so the cached Ok is trustworthy.
                    // Re-emit it so Dart re-syncs if its state drifted to
                    // Cleared/Failed from a spurious listener event, and
                    // DON'T disturb the registration during a call.
                    Log.i(TAG, "register($username@$domain) skipped — already registered (call active)")
                    onEvent?.invoke(mapOf(
                        "type" to "regState",
                        "state" to "Ok",
                        "message" to "already registered (call active)"
                    ))
                    return
                }
                // No call in flight: a cached Ok can LIE after a long
                // background. liblinphone keeps Account.state == Ok while
                // the UDP/NAT binding silently died — the FGS kept the
                // Core object alive but the socket didn't survive Doze.
                // Emitting a synthetic Ok here is exactly what produced
                // "false Active on reopen": Dart trusts it, shows the agent
                // Available/Ready, and the dialer routes calls to a phone
                // that can't receive them. Instead of trusting the cache,
                // force a real REGISTER round-trip: emit Progress so the UI
                // honestly shows "Connecting…", then verifyRegistration()
                // (refreshRegisters + 5s watchdog → forceRefresh) lands a
                // fresh 200 OK (re-emits Ok) or surfaces the failure. This
                // is the central fix for the cold-start / resume
                // false-Active gap — the status pill is derived strictly
                // from real reg state, so Dart must never see a fabricated
                // Ok it didn't earn on the wire.
                Log.i(TAG, "register($username@$domain) — cached Ok, verifying with real round-trip")
                onEvent?.invoke(mapOf(
                    "type" to "regState",
                    "state" to "Progress",
                    "message" to "verifying registration"
                ))
                verifyRegistration()
                return
            }
        }
        // Clear existing accounts so re-provisioning is idempotent
        core.clearAccounts()
        core.clearAllAuthInfo()

        val auth: AuthInfo = Factory.instance().createAuthInfo(
            username, null, password, null, null, domain
        )
        core.addAuthInfo(auth)

        val params: AccountParams = core.createAccountParams().apply {
            val identityAddr = Factory.instance().createAddress("sip:$username@$domain")!!
            setIdentityAddress(identityAddr)

            val serverAddrStr = buildString {
                append("sip:")
                append(proxy ?: domain)
                if (port != null) append(":$port")
                append(";transport=").append(transport.lowercase())
            }
            val serverAddr = Factory.instance().createAddress(serverAddrStr)!!
            serverAddr.transport = when (transport.lowercase()) {
                "tcp" -> TransportType.Tcp
                "tls" -> TransportType.Tls
                else -> TransportType.Udp
            }
            setServerAddress(serverAddr)
            isRegisterEnabled = true
            // 3600s REGISTER expiry — matches liblinphone + official
            // LinPhone app default. We previously ran 120s aiming for
            // fast dead-binding detection, but some Asterisk
            // Min-Expires policies reject sub-3600s with 423 Interval
            // Too Brief, and the retry loop was an observed cause of
            // "registration never settles" on first cold start. NAT
            // binding freshness is handled by isKeepAliveEnabled
            // (UDP, 30s) which sits well inside the binding
            // lifetime — we don't need the REGISTER cycle to do it.
            expires = 3600
            // DELIBERATELY DO NOT SET pushNotificationAllowed = true.
            // We don't wire push tokens into liblinphone (push is
            // handled by VoipFcmService waking the app), so enabling
            // the account-level push flag adds pn-* params to the
            // Contact header without a token to back them. Some
            // VICIdial Asterisk versions reject this as malformed
            // and the REGISTER never reaches Ok — observed symptom:
            // "app shows offline while native LinPhone using the
            // same creds on the same network registers fine."

            // ICE + STUN for media-path NAT traversal. Lets liblinphone
            // discover the agent's public RTP candidate via STUN and
            // signal it in SDP so Asterisk knows where to send media
            // even when the agent is behind carrier NAT. The platform
            // firewall is already open for RTP, so we don't need a TURN
            // relay — STUN-only is sufficient. The natPolicy lives on
            // the account params so it gets re-attached automatically
            // on every register / forceRefresh / wipeAccount cycle.
            //
            // Practical benefits:
            //   - Mid-call wifi↔cellular handoff: ICE can restart and
            //     re-advertise the new candidate without dropping the
            //     call (provided Asterisk has rtp_symmetric=yes, which
            //     is the VICIdial default for unconfigured peers).
            //   - First-call audio: avoids one-way audio when the
            //     agent's NAT mapping doesn't match the SDP's
            //     advertised private IP.
            //   - Faster failure detection if a media path goes dead.
            //
            // Public Google STUN as the default — no infra to operate;
            // swap to a self-hosted STUN later by changing this string.
            val nat = core.createNatPolicy().apply {
                isIceEnabled = true
                isStunEnabled = true
                stunServer = "stun.l.google.com:19302"
            }
            natPolicy = nat
        }

        val account: Account = core.createAccount(params)
        core.addAccount(account)
        core.defaultAccount = account
    }

    /**
     * Fully removes the account + auth info from Core and flushes the
     * underlying .linphonerc file so nothing about the previous SIP
     * identity survives across cold start.
     *
     * The bare `unregister()` only sets `isRegisterEnabled = false`
     * (which sends a REGISTER Expires:0 to release the AOR contact
     * cleanly on the box). It DOES NOT remove the account from
     * core.accounts or wipe the AuthInfo, and liblinphone persists
     * both to its default linphonerc in the app's files dir — so on
     * next launch the stale extension creds are still loaded into
     * Core and the user observes "the app is trying to log in the
     * old extension again."
     *
     * Caller responsibility: invoke unregister() FIRST (and ideally
     * unregisterAndWait so the Expires:0 lands on the box). Then call
     * wipeAccount() to clean up local state. The Dart-side logoutAll
     * already wires this sequence.
     */
    fun wipeAccount() {
        val hadAccount = core.defaultAccount != null
        val authCount = core.authInfoList.size
        if (!hadAccount && authCount == 0) return
        Log.i(TAG, "wipeAccount — clearing account=$hadAccount + $authCount auth-info entries")
        core.clearAccounts()
        core.clearAllAuthInfo()
        if (core.currentCall == null) {
            stopForegroundService()
        }
    }

    /**
     * Hard-reconnect path — re-adds the current default account from
     * scratch, rebuilding the SIP socket and DNS resolution. Used by
     * the network-recovery watchdog and the app-foreground trigger
     * when `core.refreshRegisters()` alone wouldn't shake out a dead
     * UDP binding.
     *
     * Idempotent and safe to call repeatedly. No-op if no account
     * is currently registered.
     */
    fun forceRefresh() {
        val existing = core.defaultAccount ?: return
        val identity = existing.params.identityAddress
        val username = identity?.username ?: return
        val domain = identity.domain ?: return
        // We need the password to re-register but Account doesn't
        // expose it. Instead, peel it from the cached AuthInfo for
        // this identity — addAuthInfo() stored it at register() time.
        val auth = core.authInfoList.firstOrNull { it.username == username }
            ?: return
        val pwd = auth.password ?: return
        val proxy = existing.params.serverAddress?.let { addr ->
            // Strip the leading "sip:" + any params after ";" so we
            // can rebuild it cleanly in register().
            addr.domain
        }
        val transport = existing.params.transport.toString().lowercase()
        val port = existing.params.serverAddress?.port?.takeIf { it > 0 }
        Log.i(TAG, "forceRefresh($username@$domain) — clearing + re-adding account")
        // Re-arm the Core's network reachability before re-adding. onLost
        // sets reachable=false; if the OS never fires onAvailable after
        // recovery (NAT idle timeout, not an interface change), the Core
        // stays unreachable and silently drops the REGISTER we're about to
        // queue — the user taps Reconnect, nothing goes on the wire, and
        // they have to physically toggle the internet. Forcing reachable
        // true here makes the manual Reconnect actually transmit.
        core.setNetworkReachable(true)
        // Skip the "already registered, no-op" early-return in
        // register() by clearing first. We WANT the re-add even if
        // state == Ok, because the underlying socket may be dead.
        core.clearAccounts()
        register(username, pwd, domain, proxy, transport, port)
    }

    fun unregister() {
        core.defaultAccount?.let { acc ->
            val p = acc.params.clone()
            p.isRegisterEnabled = false
            acc.params = p
        }
        // The registration-state listener will fire Cleared / None and shut
        // the idle FGS down, but stop it eagerly here too so re-provisioning
        // mid-call doesn't leave a stale notification.
        if (core.currentCall == null) {
            stopForegroundService()
        }
    }

    fun registrationState(): String =
        core.defaultAccount?.state?.name ?: "None"

    /** True while any call exists (including paused/held). Used to avoid
     *  yanking the registration out from under an in-progress call when the
     *  app task is swiped away. */
    fun hasActiveCall(): Boolean = core.calls.isNotEmpty()

    // ---- Calls -------------------------------------------------------------

    fun placeCall(to: String): String? {
        val addr = core.interpretUrl(to, false) ?: return null
        val params = core.createCallParams(null) ?: return null
        val call = core.inviteAddressWithParams(addr, params)
        return call?.callLog?.callId
    }

    fun answer() {
        core.currentCall?.accept()
    }

    fun hangup() {
        // Single convergence point for ALL agent-initiated hangups —
        // in-app red button (via Dart bridge), pre-answer Decline,
        // lock-screen End Call (SipConnectionService.onDisconnect),
        // notification "Hang up" chip (SipCallActionReceiver). Caller-
        // initiated BYEs never enter this function; they're handled by
        // liblinphone's internal call-state machine, which still fires
        // the regular callState=ended event but skips this signal.
        //
        // Emit the intent BEFORE terminate() so the EventChannel
        // delivers it to Dart ahead of the callState=ended event that
        // terminate() will eventually generate (same channel, same
        // thread, FIFO ordering). AgentController._watchCallEnd
        // watches `lastHangupIntentAt` transitions and arms
        // `pendingDispoHangupBy='agent'` exactly once per hangup.
        onEvent?.invoke(mapOf("type" to "agentInitiatedHangup"))
        core.currentCall?.terminate() ?: core.terminateAllCalls()
    }

    /**
     * Terminate a call that the Android Telecom framework auto-rejected
     * or dropped WITHOUT the agent tapping anything — Do-Not-Disturb,
     * another (cellular) call taking priority, call-screening, or
     * onCreateIncomingConnectionFailed. Functionally identical to
     * [hangup] (still terminates the liblinphone call) but emits a
     * DISTINCT `systemRejectedCall` signal instead of
     * `agentInitiatedHangup`, so the Dart side does NOT attribute the
     * dispo write to the agent. Without this split, a missed/blocked
     * inbound call was recorded as if the agent hung up → wrong
     * disposition + skewed stats.
     */
    fun hangupSystemRejected() {
        onEvent?.invoke(mapOf("type" to "systemRejectedCall"))
        core.currentCall?.terminate() ?: core.terminateAllCalls()
    }

    fun sendDtmf(digit: Char) {
        // core.currentCall is null while the call is on hold ("current"
        // = actively in conversation), so a DTMF tapped on a held call
        // would silently drop. Fall back to core.calls — DTMF rides the
        // RFC2833 / SIP-INFO channel independently of the paused audio
        // direction, so it still reaches the PBX (agents send digits to
        // IVRs while the customer is parked on MOH). Mirrors setHold's
        // resolution order.
        // Linphone sends per Core's RFC2833 / SIP-INFO settings; we enable
        // both at Core init so the digit reaches PBXs that expect either.
        val c = core.currentCall ?: core.calls.firstOrNull() ?: run {
            Log.w(TAG, "sendDtmf($digit) ignored — no call found")
            return
        }
        c.sendDtmf(digit)
    }

    fun setMute(muted: Boolean) {
        // Mute at both Core and Call level — liblinphone 5.x requires the
        // per-call flag to take effect mid-conversation on some devices.
        core.isMicEnabled = !muted
        core.currentCall?.microphoneMuted = muted
    }

    fun setHold(on: Boolean) {
        // core.currentCall returns null when the call is in Paused
        // state ("current" = actively in conversation). Resume would
        // silently no-op without the fallback to core.calls — UI
        // would stay stuck in "Hold" mode with no way out.
        val c = core.currentCall
            ?: core.calls.firstOrNull()
            ?: run {
                Log.w(TAG, "setHold($on) ignored — no call found")
                return
            }
        // liblinphone returns 0 on success, non-zero on failure (the
        // PBX rejected the re-INVITE, no media to renegotiate, etc.).
        val rc = if (on) c.pause() else c.resume()
        if (rc != 0) {
            Log.w(TAG, "setHold($on) liblinphone returned $rc — call.state=${c.state}")
        }
    }

    fun setSpeaker(on: Boolean) {
        val target: AudioDevice = core.audioDevices.firstOrNull {
            if (on) it.type == AudioDevice.Type.Speaker
            else it.type == AudioDevice.Type.Earpiece
        } ?: return
        core.outputAudioDevice = target
        // Per-call override so the change is immediate even if Core already
        // had a different default.
        core.currentCall?.outputAudioDevice = target
    }

    fun currentCallSnapshot(): Map<String, Any?>? =
        core.currentCall?.let { callSnapshot(it) }

    private fun callSnapshot(call: Call): Map<String, Any?> = mapOf(
        "callId" to call.callLog.callId,
        "remoteUri" to call.remoteAddress.asStringUriOnly(),
        "remoteDisplay" to (call.remoteAddress.displayName ?: call.remoteAddress.username),
        "direction" to if (call.dir == Call.Dir.Incoming) "incoming" else "outgoing",
        "state" to call.state.name,
        "durationSec" to call.duration
    )

    // ---- Foreground service helpers ---------------------------------------

    /** Pick the best human-readable label for a SIP peer.
     *
     * Mirrors the Dart-side `SipCall.displayLabel` (sip_models.dart) so
     * notifications, the FGS chip, and Telecom's caller display all
     * agree with the in-app `IncomingCallScreen` / `Recents` text.
     *
     * VICIdial puts the lead's internal uniqueid (e.g.
     * `Y522344110000000016`) in the SIP From display-name for its own
     * tracking. The real caller number lives in the URI user part. If
     * the display-name matches `^Y\d{15,20}$` we ignore it and use the
     * username (the number); otherwise we trust the display-name
     * (could be a CNAM-resolved real name, or a manually-provisioned
     * SIP user's extension).
     */
    private fun peerDisplayLabel(call: Call): String {
        val addr = call.remoteAddress
        val display = addr.displayName
        if (!display.isNullOrEmpty() && !uniqueidPattern.matches(display)) {
            return display
        }
        val user = addr.username
        if (!user.isNullOrEmpty()) return user
        return "Ongoing call"
    }

    private val uniqueidPattern = Regex("^Y\\d{15,20}$")

    private fun startForegroundService(caller: String) {
        SipForegroundService.startInCall(appContext, caller)
    }

    private fun startRegisteredForegroundService(account: Account) {
        val username = account.params.identityAddress?.username ?: "VICIfast"
        val domain = account.params.identityAddress?.domain
        val label = if (domain.isNullOrEmpty()) username else "$username@$domain"
        SipForegroundService.startRegistered(appContext, label)
    }

    private fun stopForegroundService() {
        SipForegroundService.stop(appContext)
    }
}
