package io.vicifast.vicifast_phone.sip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.os.bundleOf
import io.vicifast.vicifast_phone.MainActivity

/**
 * Surfaces incoming SIP calls in Android's native lock-screen / full-screen ringer UI
 * by registering a self-managed PhoneAccount with the Telecom subsystem.
 *
 * Why self-managed: lets us own the audio and UX while Android still draws the
 * system ringer overlay and respects Do-Not-Disturb / call-screening rules.
 */
class SipConnectionService : ConnectionService() {

    companion object {
        private const val ACCOUNT_ID = "vicifast_sip_account"
        // v2 channel: the v1 channel baked its own single-shot ringtone
        // sound into the channel config, which can't be changed after
        // creation. We now own the ring ourselves via a LOOPING Ringtone
        // (see [startRingtone]) so it keeps ringing until answered /
        // rejected / timed out instead of playing once and going silent.
        // The v2 channel is therefore SILENT — bumping the id forces the
        // new silent config to take on upgrades where the old channel is
        // frozen at its sound-playing settings.
        private const val INCOMING_CHANNEL_ID = "vicifast_incoming_call_v2"
        private const val INCOMING_NOTIFICATION_ID = 9101

        // Looping ringtone we drive for the incoming-call window. The
        // notification channel no longer plays a sound (see above), so
        // this is the single source of the ring — started in
        // [reportIncoming], stopped on answer / hangup / dismissal.
        // Guarded by its own lock; Telecom callbacks + liblinphone
        // events arrive on different threads.
        private val ringtoneLock = Any()
        private var ringtone: Ringtone? = null
        // Pre-API-28 has no Ringtone.isLooping; re-play on a short cadence
        // so the ring keeps going. Cancelled by [stopRingtone]. Main-loop
        // handler so Ringtone touches stay on one thread.
        private val ringHandler = android.os.Handler(android.os.Looper.getMainLooper())
        private val ringLoopToken = Any()

        fun phoneAccountHandle(context: Context): PhoneAccountHandle =
            PhoneAccountHandle(
                ComponentName(context, SipConnectionService::class.java),
                ACCOUNT_ID
            )

        /** Call at app boot. Best-effort and idempotent.
         *
         * We deliberately skip the `getPhoneAccount` idempotency check: on
         * Android 14+ it requires READ_PHONE_NUMBERS, a runtime permission
         * we don't need for anything else. Telecom's
         * `registerPhoneAccount` is itself idempotent for self-managed
         * accounts (replaces the existing handle), so we just call it
         * unconditionally. Any failure is logged and swallowed so a Telecom
         * misconfiguration can never crash app launch.
         */
        fun ensureRegistered(context: Context) {
            try {
                val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                val handle = phoneAccountHandle(context)
                val account = PhoneAccount.builder(handle, "VICIfast")
                    .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                    .setShortDescription("SIP calls")
                    .build()
                tm.registerPhoneAccount(account)
            } catch (t: Throwable) {
                Log.w("VicifastTelecom", "registerPhoneAccount failed: ${t.message}")
            }
        }

        /** Called from [LinphoneManager] when liblinphone reports IncomingReceived. */
        fun reportIncoming(context: Context, callId: String, from: String) {
            // Force the screen on. Telecom self-managed PhoneAccount +
            // fullScreenIntent are supposed to wake the device, but on
            // many OEMs (Samsung One UI, Xiaomi MIUI, etc.) they don't —
            // the device just rings with the screen black. A short
            // SCREEN_BRIGHT wake lock with ACQUIRE_CAUSES_WAKEUP is the
            // reliable signal the system uses for "this is a call,
            // light up the display NOW". 10s ceiling so a hung call
            // can't drain the battery if events stop firing.
            acquireIncomingCallWakeLock(context)
            startRingtone(context)
            ensureRegistered(context)
            try {
                val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                val handle = phoneAccountHandle(context)
                val extras = bundleOf(
                    TelecomManager.EXTRA_INCOMING_CALL_ADDRESS to Uri.fromParts("sip", from, null),
                    "vicifast_call_id" to callId,
                    "vicifast_caller" to from,
                )
                if (tm.isIncomingCallPermitted(handle)) {
                    tm.addNewIncomingCall(handle, extras)
                }
            } catch (t: Throwable) {
                // If Telecom rejects the incoming call surface (perms, DnD,
                // OEM quirks), our in-app IncomingCallScreen still fires from
                // the Dart event stream — don't crash the listener.
                Log.w("VicifastTelecom", "addNewIncomingCall failed: ${t.message}")
            }
            // For self-managed PhoneAccounts, Telecom plays the ringer +
            // owns audio focus but does NOT render any call UI for us.
            // Post a high-priority notification with a fullScreenIntent
            // that launches MainActivity so the IncomingCallScreen
            // (Dart-side) renders over the lock screen. Without this,
            // the device rings but nothing shows — the original bug.
            showIncomingCallNotification(context, from)
        }

        @Suppress("DEPRECATION")
        private fun acquireIncomingCallWakeLock(context: Context) {
            try {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                // SCREEN_BRIGHT_WAKE_LOCK is technically deprecated but it's
                // the only level that turns the screen ON from off. The
                // recommended replacement (turnScreenOn activity attribute)
                // only works when the activity is launched fresh — useless
                // when MainActivity is already running and we re-enter via
                // onNewIntent.
                val wl = pm.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                        PowerManager.ACQUIRE_CAUSES_WAKEUP or
                        PowerManager.ON_AFTER_RELEASE,
                    "vicifast:incoming-call",
                )
                wl.setReferenceCounted(false)
                wl.acquire(10_000L)
            } catch (t: Throwable) {
                Log.w("VicifastTelecom", "acquireIncomingCallWakeLock failed: ${t.message}")
            }
        }

        /**
         * Start the incoming-call ring and keep it LOOPING until the
         * call is answered, rejected, or times out. The notification
         * channel is silent (see [INCOMING_CHANNEL_ID]); this is the
         * single source of the ring so it can't play once and fall
         * silent the way a channel sound does.
         *
         * Respects the ringer mode: SILENT/VIBRATE → no ring (the
         * CallStyle notification's own vibration still fires). On API
         * 28+ we set the native looping flag; below that we schedule a
         * re-play watchdog on the main thread.
         */
        private fun startRingtone(context: Context) {
            synchronized(ringtoneLock) {
                if (ringtone != null) return
                try {
                    val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    // Don't ring when the phone is set to silent/vibrate —
                    // matches how the native dialer behaves. setBypassDnd
                    // on the channel covers DnD; the ringer-mode check
                    // covers the user's explicit silent choice.
                    if (am.ringerMode == AudioManager.RINGER_MODE_SILENT ||
                        am.ringerMode == AudioManager.RINGER_MODE_VIBRATE
                    ) {
                        return
                    }
                    val uri = RingtoneManager.getActualDefaultRingtoneUri(
                        context, RingtoneManager.TYPE_RINGTONE,
                    ) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    val rt = RingtoneManager.getRingtone(context, uri) ?: return
                    rt.audioAttributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        rt.isLooping = true
                    }
                    rt.play()
                    ringtone = rt
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                        scheduleRingReplay()
                    }
                } catch (t: Throwable) {
                    Log.w("VicifastTelecom", "startRingtone failed: ${t.message}")
                }
            }
        }

        /** Pre-28 fallback: re-play the ring when it stops, until
         *  [stopRingtone] clears it. */
        private fun scheduleRingReplay() {
            // postAtTime(Runnable, token, uptime) is API 1 — the
            // (Runnable, token, delay) overload is only API 28, and this
            // path runs on < 28. The token lets [stopRingtone] cancel via
            // removeCallbacksAndMessages(token).
            ringHandler.postAtTime({
                synchronized(ringtoneLock) {
                    val rt = ringtone ?: return@postAtTime
                    try {
                        if (!rt.isPlaying) rt.play()
                    } catch (_: Throwable) {}
                    scheduleRingReplay()
                }
            }, ringLoopToken, android.os.SystemClock.uptimeMillis() + 1_000L)
        }

        /** Stop + release the looping ring. Idempotent — safe to call on
         *  every terminal path (answer, reject, remote hangup, dismiss). */
        private fun stopRingtone() {
            synchronized(ringtoneLock) {
                ringHandler.removeCallbacksAndMessages(ringLoopToken)
                try {
                    ringtone?.let { if (it.isPlaying) it.stop() }
                } catch (t: Throwable) {
                    Log.w("VicifastTelecom", "stopRingtone failed: ${t.message}")
                } finally {
                    ringtone = null
                }
            }
        }

        private fun showIncomingCallNotification(context: Context, from: String) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager

                // Lazy-create the channel. IMPORTANCE_HIGH is required for
                // fullScreenIntent + heads-up to actually surface; the OEM
                // overlay UI for incoming calls won't appear at lower
                // importance levels.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val existing = nm.getNotificationChannel(INCOMING_CHANNEL_ID)
                    if (existing == null) {
                        val ch = NotificationChannel(
                            INCOMING_CHANNEL_ID,
                            "Incoming calls",
                            NotificationManager.IMPORTANCE_HIGH,
                        ).apply {
                            description = "Ringer and full-screen UI for incoming VICIfast calls"
                            setBypassDnd(true)
                            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                            enableVibration(true)
                            // No channel sound: the ring is driven by our
                            // own looping Ringtone in [startRingtone], so a
                            // channel sound here would double-ring for the
                            // first cycle and then fall silent (channel
                            // sounds play once, they don't loop).
                            setSound(null, null)
                        }
                        nm.createNotificationChannel(ch)
                    }
                }

                // Activity intent for the fullScreenIntent + content tap
                // (screen-off lock screen). MainActivity's manifest flags
                // + onNewIntent re-application of showWhenLocked/turnScreenOn
                // bring it up over the keyguard.
                val fullScreenIntent = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    action = "io.vicifast.phone.action.SHOW_INCOMING"
                }
                val fullScreenPi = PendingIntent.getActivity(
                    context,
                    0,
                    fullScreenIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )

                // Answer = a getActivity PendingIntent that launches
                // MainActivity DIRECTLY. It must NOT be a broadcast that
                // then calls startActivity(): Android 12+ bans that
                // notification-trampoline (a BroadcastReceiver/Service
                // starting an Activity from the background), and the
                // launch silently no-ops — the agent taps Answer, the
                // call connects with audio, but the in-call screen never
                // comes up. Launching the Activity straight from the
                // notification action is the allowed path. MainActivity
                // reads ACTION_ANSWER and calls LinphoneManager.answer()
                // on its Core thread. Decline stays a broadcast — it only
                // hangs up (no Activity launch), which is always allowed.
                //
                // Request codes 10/11 deliberately skip 1 — that's the
                // code SipForegroundService uses for the in-call HANGUP
                // pendingintent. PendingIntents with the same target and
                // request code are coalesced by the framework even when
                // their action differs (FLAG_UPDATE_CURRENT updates the
                // existing one), which would silently break the in-call
                // hangup chip once an incoming notification has been
                // posted in the same process lifetime.
                val answerPi = PendingIntent.getActivity(
                    context,
                    10,
                    Intent(context, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                        action = SipCallActionReceiver.ACTION_ANSWER
                        putExtra(SipCallActionReceiver.EXTRA_TOKEN, SipCallActionReceiver.ANSWER_TOKEN)
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val declinePi = PendingIntent.getBroadcast(
                    context,
                    11,
                    Intent(context, SipCallActionReceiver::class.java).apply {
                        action = SipCallActionReceiver.ACTION_REJECT
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )

                // CallStyle.forIncomingCall is the canonical Android-12+
                // notification for incoming calls. On supported versions
                // the system renders it as a full-screen UI on the lock
                // screen (the WhatsApp / native dialer look), with native
                // Answer + Decline buttons that bypass the app entirely.
                // On older versions it gracefully degrades to a heads-up
                // notification with the same Answer/Decline actions.
                //
                // The fullScreenIntent is the screen-locked auto-launch
                // path — when the screen is off and a call comes in, the
                // OS launches MainActivity over the keyguard so the
                // /incoming Flutter screen renders even before the user
                // touches anything.
                val caller = Person.Builder()
                    .setName(from)
                    .setImportant(true)
                    .build()
                val notification = NotificationCompat.Builder(context, INCOMING_CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.sym_call_incoming)
                    .setStyle(
                        NotificationCompat.CallStyle.forIncomingCall(
                            caller, declinePi, answerPi,
                        ),
                    )
                    .setPriority(NotificationCompat.PRIORITY_MAX)
                    .setCategory(NotificationCompat.CATEGORY_CALL)
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    .setOngoing(true)
                    .setAutoCancel(false)
                    .setContentIntent(fullScreenPi)
                    .setFullScreenIntent(fullScreenPi, true)
                    .build()

                nm.notify(INCOMING_NOTIFICATION_ID, notification)
            } catch (t: Throwable) {
                Log.w("VicifastTelecom", "showIncomingCallNotification failed: ${t.message}")
            }
        }

        private fun dismissIncomingCallNotification(context: Context) {
            // Stop the loop first — dismissal is the single convergence
            // point for answer (setActive), remote hangup, and in-app
            // reject (endCall), so the ring can't outlive the call.
            stopRingtone()
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                nm.cancel(INCOMING_NOTIFICATION_ID)
            } catch (t: Throwable) {
                Log.w("VicifastTelecom", "dismissIncomingCallNotification failed: ${t.message}")
            }
        }

        // Active self-managed Telecom connections — kept so liblinphone
        // state-change events can drive the Connection's UI state (stop
        // ringing on answer, dismiss on hangup). The platform does NOT
        // auto-dispose self-managed connections; if we never call
        // setDisconnected()+destroy(), the lock-screen notification + ringer
        // run forever. Set is small (≤1 in practice), but we hold a list
        // for safety. Mutations are synchronised — Telecom callbacks and
        // liblinphone events arrive on different threads.
        private val activeConnections = mutableSetOf<SipConnection>()

        internal fun registerConnection(c: SipConnection) {
            synchronized(activeConnections) { activeConnections.add(c) }
        }

        internal fun unregisterConnection(c: SipConnection) {
            synchronized(activeConnections) { activeConnections.remove(c) }
        }

        /**
         * Bridge liblinphone Call.State.Connected / StreamsRunning → Telecom
         * setActive(). Stops the OS ringer + vibration the moment the call
         * is answered (whether the user tapped Answer on the native ringer
         * UI or on our in-app IncomingCallScreen).
         */
        fun setActive(context: Context) {
            val snapshot = synchronized(activeConnections) { activeConnections.toList() }
            for (conn in snapshot) {
                try {
                    conn.setActive()
                } catch (t: Throwable) {
                    Log.w("VicifastTelecom", "setActive failed: ${t.message}")
                }
            }
            // Dismiss the incoming-call notification as soon as the call
            // becomes active. The SipForegroundService's own ongoing-call
            // notification takes over from here.
            dismissIncomingCallNotification(context)
        }

        /**
         * Bridge liblinphone Paused / PausedByRemote / Resuming → Telecom
         * hold state. Keeps the lock-screen UI honest while the call is
         * parked.
         */
        fun setOnHold(context: Context, held: Boolean) {
            val snapshot = synchronized(activeConnections) { activeConnections.toList() }
            for (conn in snapshot) {
                try {
                    if (held) conn.setOnHold() else conn.setActive()
                } catch (t: Throwable) {
                    Log.w("VicifastTelecom", "setOnHold failed: ${t.message}")
                }
            }
        }

        /**
         * Bridge liblinphone Call.State.End / Released / Error → Telecom
         * setDisconnected() + destroy(). This is what dismisses the lock-
         * screen notification and stops the OS ringer. Must run on EVERY
         * call termination — remote hangup, our in-app hangup, network
         * failure, busy, etc. — because self-managed connections aren't
         * auto-cleaned.
         */
        fun endCall(context: Context) {
            // Snapshot + clear under lock so concurrent SipConnection.onReject
            // / onDisconnect calls don't double-destroy.
            val snapshot = synchronized(activeConnections) {
                val copy = activeConnections.toList()
                activeConnections.clear()
                copy
            }
            for (conn in snapshot) {
                try {
                    conn.setDisconnected(DisconnectCause(DisconnectCause.REMOTE))
                    conn.destroy()
                } catch (t: Throwable) {
                    Log.w("VicifastTelecom", "endCall failed: ${t.message}")
                }
            }
            // Always dismiss the incoming-call notification — covers
            // remote hangup before answer, our in-app reject, and the
            // user accepting on the native ringer UI (which is followed
            // by a Connected -> setActive sequence and a fresh in-call
            // surface, so the incoming-call notif has done its job).
            dismissIncomingCallNotification(context)
        }
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest
    ): Connection {
        val caller = request.extras.getString("vicifast_caller") ?: "Unknown"
        return SipConnection(applicationContext, isIncoming = true, caller = caller).apply {
            setRinging()
            setCallerDisplayName(caller, android.telecom.TelecomManager.PRESENTATION_ALLOWED)
            setAddress(request.address ?: Uri.fromParts("sip", caller, null),
                android.telecom.TelecomManager.PRESENTATION_ALLOWED)
            audioModeIsVoip = true
        }
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest
    ): Connection {
        val target = request.address?.schemeSpecificPart ?: "unknown"
        return SipConnection(applicationContext, isIncoming = false, caller = target).apply {
            setDialing()
            setCallerDisplayName(target, android.telecom.TelecomManager.PRESENTATION_ALLOWED)
            setAddress(request.address, android.telecom.TelecomManager.PRESENTATION_ALLOWED)
            audioModeIsVoip = true
        }
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        // Telecom refused the incoming call (DnD, busy, another call has
        // priority, call-screening, OEM policy). This is a SYSTEM reject,
        // not the agent declining — route through hangupSystemRejected()
        // so the dispo write isn't attributed to the agent.
        LinphoneManager.getInstance(applicationContext).hangupSystemRejected()
    }
}

/**
 * Single SIP call surface presented to Telecom. The user's accept/reject actions on the
 * native incoming-call UI are routed through this class back into liblinphone.
 */
class SipConnection(
    private val ctx: Context,
    val isIncoming: Boolean,
    val caller: String
) : Connection() {

    init {
        connectionProperties = PROPERTY_SELF_MANAGED
        connectionCapabilities = CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD or CAPABILITY_MUTE
        // Track this connection so SipConnectionService.endCall() can find
        // it when liblinphone fires Call.State.End (remote hangup, in-app
        // hangup via Dart, network failure, etc.). Without this the static
        // endCall() has nothing to disconnect and the lock-screen UI
        // sticks until the user clears it manually.
        SipConnectionService.registerConnection(this)
    }

    override fun onAnswer() {
        LinphoneManager.getInstance(ctx).answer()
        setActive()
    }

    override fun onReject() {
        // Telecom framework reject of this self-managed connection —
        // system/OEM DnD, call-screening, or another call preempting
        // ours. The agent's OWN Decline button (native ringer + our
        // CallStyle notification) fires ACTION_REJECT to
        // SipCallActionReceiver → LinphoneManager.hangup(), NOT this
        // callback, so treating onReject as a system reject keeps a
        // missed/blocked call out of the agent-hangup attribution.
        LinphoneManager.getInstance(ctx).hangupSystemRejected()
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        SipConnectionService.unregisterConnection(this)
        destroy()
    }

    override fun onDisconnect() {
        // User tapped End Call on the native in-call / lock-screen UI —
        // an agent-initiated hangup.
        LinphoneManager.getInstance(ctx).hangup()
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        SipConnectionService.unregisterConnection(this)
        destroy()
    }

    override fun onHold() {
        LinphoneManager.getInstance(ctx).setHold(true)
        setOnHold()
    }

    override fun onUnhold() {
        LinphoneManager.getInstance(ctx).setHold(false)
        setActive()
    }

    override fun onMuteStateChanged(isMuted: Boolean) {
        LinphoneManager.getInstance(ctx).setMute(isMuted)
    }

    override fun onPlayDtmfTone(c: Char) {
        LinphoneManager.getInstance(ctx).sendDtmf(c)
    }
}
