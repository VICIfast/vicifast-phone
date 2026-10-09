package io.vicifast.vicifast_phone.sip

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import io.vicifast.vicifast_phone.MainActivity
import io.vicifast.vicifast_phone.R

/**
 * Foreground service that keeps the SIP stack alive. Two modes:
 *
 *  - [MODE_REGISTERED]: idle keep-alive while an account is registered. Runs
 *    with foregroundServiceType=dataSync so the SIP REGISTER socket survives
 *    Doze and screen lock without claiming the microphone.
 *  - [MODE_IN_CALL]: active call. Runs with phoneCall (+ microphone if the
 *    user has granted RECORD_AUDIO) so audio capture is allowed.
 *
 * The service can swap modes live by calling startForeground() again — the
 * Android framework treats it as an update.
 */
class SipForegroundService : Service() {

    companion object {
        private const val TAG = "VicifastFgs"
        // Two distinct notification IDs — using a single ID and calling
        // startForeground() with a new notification only "updates" the
        // existing one in place. For the call→idle transition that's a
        // problem: the CallStyle notification (chronometer, big "Hang
        // up" action) is rendered specially on the lock screen, and on
        // many Android versions the system caches that special view
        // even after the underlying notification has been demoted to a
        // plain service notif. The result: post-hangup the user sees
        // the stale "Active call · 00:42" running on the lock screen.
        //
        // Using separate IDs + an explicit stopForeground(REMOVE) in
        // between forces the OS to tear down the old view completely
        // and render the new one from scratch — no carry-over.
        private const val NOTIF_ID_IDLE = 0x5191
        private const val NOTIF_ID_CALL = 0x5192

        private const val CHANNEL_IDLE = "vicifast_sip_idle"
        private const val CHANNEL_CALL = "vicifast_sip_call"

        const val MODE_REGISTERED = "registered"
        const val MODE_IN_CALL = "in_call"

        const val EXTRA_MODE = "mode"
        const val EXTRA_CALLER = "caller"
        const val EXTRA_ACCOUNT = "account"

        /** What the pinned notification says while no call is active. Set from Dart. */
        @Volatile
        var statusText: String = "Connected"

        @Volatile
        private var running: SipForegroundService? = null

        fun updateStatus(text: String) {
            statusText = text
            running?.refreshIdleNotification()
        }

        /** Idle keep-alive type. dataSync is capped at 6 hours a day from Android 15;
         *  specialUse (14+) has no cap, which an 8-hour shift needs. */
        private fun idleType(): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC

        fun startRegistered(ctx: Context, account: String?) {
            // The idle keep-alive runs as a dataSync FGS. On Android 12+
            // the OS blocks starting a background FGS from most contexts,
            // and Android 15 (API 35) specifically bans a dataSync FGS
            // started off BOOT_COMPLETED (or any background wake) —
            // startForegroundService() would throw
            // ForegroundServiceStartNotAllowedException and, from a
            // BroadcastReceiver like BootReceiver, crash the process.
            //
            // So only arm the idle FGS when we're in an allowed context
            // (app process at foreground-ish importance). If we're waking
            // from boot / doze in the background, skip it: liblinphone's
            // Core keeps iterating and answering OPTIONS qualify in-process
            // regardless, and the FGS re-arms the moment the agent next
            // brings the app to the foreground. The in-call path
            // (startInCall, phoneCall type) is NOT gated — phoneCall FGS is
            // exempt from the background-start ban.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                !isForegroundContext()
            ) {
                Log.i(TAG, "Skipping idle FGS start from background context (boot/doze)")
                return
            }
            val intent = Intent(ctx, SipForegroundService::class.java).apply {
                putExtra(EXTRA_MODE, MODE_REGISTERED)
                putExtra(EXTRA_ACCOUNT, account ?: "")
            }
            startServiceCompat(ctx, intent)
        }

        /**
         * True when our process is running at a foreground-ish importance
         * — i.e. an allowed context for starting a dataSync FGS. Used to
         * gate the idle keep-alive so a background/boot wake doesn't trip
         * ForegroundServiceStartNotAllowedException. Errs on the side of
         * "allowed" if importance can't be read.
         */
        private fun isForegroundContext(): Boolean {
            return try {
                // getMyMemoryState is static — fills `info` with THIS
                // process's current importance. Lower importance value =
                // more foreground; a backgrounded/cached app sits well
                // above IMPORTANCE_FOREGROUND_SERVICE, so the <= check is
                // true only when we're actually in an allowed context.
                val info = android.app.ActivityManager.RunningAppProcessInfo()
                android.app.ActivityManager.getMyMemoryState(info)
                info.importance <=
                    android.app.ActivityManager.RunningAppProcessInfo
                        .IMPORTANCE_FOREGROUND_SERVICE
            } catch (t: Throwable) {
                true
            }
        }

        fun startInCall(ctx: Context, caller: String?) {
            val intent = Intent(ctx, SipForegroundService::class.java).apply {
                putExtra(EXTRA_MODE, MODE_IN_CALL)
                putExtra(EXTRA_CALLER, caller ?: "Ongoing call")
            }
            startServiceCompat(ctx, intent)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, SipForegroundService::class.java))
        }

        private fun startServiceCompat(ctx: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Whichever notification ID is currently posted as the FGS surface. */
    private var currentNotifId: Int = NOTIF_ID_IDLE

    private var lastAccount: String = ""

    override fun onCreate() {
        super.onCreate()
        ensureChannels()
        running = this
    }

    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }

    fun refreshIdleNotification() {
        if (currentNotifId != NOTIF_ID_IDLE) return
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID_IDLE, buildRegisteredNotification(lastAccount))
        } catch (t: Throwable) {
            Log.w(TAG, "status notification update failed", t)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mode = intent?.getStringExtra(EXTRA_MODE) ?: MODE_REGISTERED
        if (mode == MODE_IN_CALL) {
            val caller = intent?.getStringExtra(EXTRA_CALLER) ?: "Ongoing call"
            switchMode(
                NOTIF_ID_CALL,
                buildInCallNotification(caller),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
                    if (hasMic())
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    else 0,
            )
        } else {
            val account = intent?.getStringExtra(EXTRA_ACCOUNT) ?: ""
            lastAccount = account
            switchMode(
                NOTIF_ID_IDLE,
                buildRegisteredNotification(account),
                idleType(),
            )
        }
        return START_STICKY
    }

    /**
     * The agent swiped the app away from recents — an intentional close /
     * end of shift. This is distinct from Home/lock, which never trigger
     * onTaskRemoved: those must KEEP the registration alive so the agent
     * still receives calls on the lock screen (issue #6). On a genuine close
     * we drop the SIP registration so Asterisk loses the contact and the
     * box's phone-watcher pulls the remote agent off the floor
     * (vicidial_remote_agents.status -> INACTIVE) instead of leaving it
     * falsely Ready while the phone is gone.
     *
     * Because Core.isAutoIterateEnabled keeps liblinphone answering OPTIONS
     * qualify for as long as this foreground service holds the process
     * alive, without this the contact stays reachable and the RA never
     * goes off-floor on close.
     *
     * Guard: if a call is in progress, leave everything intact — the in-call
     * FGS keeps the call up and we don't yank the registration mid-call.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        try {
            val mgr = LinphoneManager.getInstance(applicationContext)
            if (!mgr.hasActiveCall()) {
                mgr.unregister()
                // Stop explicitly so START_STICKY can't resurrect us (a
                // restart would re-arm the registration). A real close
                // stays closed.
                stopSelf()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "onTaskRemoved cleanup failed: ${t.message}")
        }
        super.onTaskRemoved(rootIntent)
    }

    /**
     * Transition the FGS notification cleanly. If we're changing IDs (i.e.
     * actually switching modes), first detach + cancel the prior
     * notification so its lock-screen view is fully torn down before the
     * new one is posted — otherwise CallStyle from the in-call notif
     * leaks through to the idle state.
     */
    private fun switchMode(notifId: Int, notification: Notification, type: Int) {
        if (currentNotifId != notifId) {
            try {
                // detach prior FGS notif from foreground status + remove it
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                // belt-and-braces: explicitly cancel in case the detach
                // didn't dismiss (some OEMs hold CallStyle notifs longer
                // than the FGS lifetime).
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(currentNotifId)
            } catch (t: Throwable) {
                Log.w(TAG, "stopForeground/cancel during mode switch failed: ${t.message}")
            }
        }
        currentNotifId = notifId
        goForeground(notifId, notification, type)
    }

    private fun goForeground(notifId: Int, notification: Notification, type: Int) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(notifId, notification, type)
            } else {
                startForeground(notifId, notification)
            }
        } catch (t: SecurityException) {
            // Android 14 refuses FGS-microphone without RECORD_AUDIO. Retry
            // with just the phoneCall bit so the call surface still works;
            // microphone capture begins once the user grants permission.
            Log.w(TAG, "FGS start failed (${t.message}); retrying without microphone")
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val fallback = (type and ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE.inv())
                        .let { if (it == 0) idleType() else it }
                    startForeground(notifId, notification, fallback)
                } else {
                    startForeground(notifId, notification)
                }
            } catch (t2: Throwable) {
                Log.e(TAG, "FGS fallback also failed", t2)
                stopSelf()
            }
        } catch (t: Throwable) {
            // ForegroundServiceStartNotAllowedException (API 31+, an
            // IllegalStateException subclass) lands here — thrown when the
            // OS won't let us promote to foreground from the current
            // context. The classic trigger is a dataSync (idle keep-alive)
            // start off the back of BOOT_COMPLETED or another background
            // wake: Android 12+ restricts background FGS starts, and
            // Android 15 bans dataSync FGS from BOOT_COMPLETED outright.
            //
            // We MUST NOT let this crash the process — a boot-time
            // re-register would otherwise take the whole app down. The FGS
            // is a keep-alive optimisation, not load-bearing: liblinphone's
            // Core keeps iterating in-process regardless, so registration
            // still works. Swallow, log, and stop this (never-foregrounded)
            // service instance. It re-arms cleanly the next time we're in an
            // allowed context — the user opening the app, or an incoming
            // call (phoneCall FGS is exempt from the background-start ban).
            Log.w(TAG, "FGS start not allowed from this context (${t.message}); continuing without FGS")
            stopSelf()
        }
    }

    private fun hasMic(): Boolean =
        ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun hangupIntent(): PendingIntent = PendingIntent.getBroadcast(
        this,
        1,
        Intent(this, SipCallActionReceiver::class.java).apply {
            action = SipCallActionReceiver.ACTION_HANGUP
        },
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun buildRegisteredNotification(account: String): Notification {
        val title = if (account.isEmpty()) "VICIfast" else "Connected as $account"
        val builder = NotificationCompat.Builder(this, CHANNEL_IDLE)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(statusText)
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        val n = builder.build()
        n.flags = n.flags or Notification.FLAG_NO_CLEAR or Notification.FLAG_ONGOING_EVENT
        return n
    }

    private fun buildInCallNotification(caller: String): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_CALL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            // No heads-up: channel is LOW importance and we keep priority LOW.
            // The CallStyle + ongoing flags keep it pinned on the lock screen.
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder().setName(caller).setImportant(true).build()
            builder
                .setStyle(
                    NotificationCompat.CallStyle.forOngoingCall(person, hangupIntent()),
                )
                .setContentTitle(caller)
        } else {
            builder
                .setContentTitle("VICIfast")
                .setContentText(caller)
                .addAction(R.mipmap.ic_launcher, "Hang up", hangupIntent())
        }
        val n = builder.build()
        n.flags = n.flags or Notification.FLAG_NO_CLEAR or Notification.FLAG_ONGOING_EVENT
        return n
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Idle keep-alive — lowest importance so it doesn't show in
        // status bar by itself, only in the shade.
        if (nm.getNotificationChannel(CHANNEL_IDLE) == null) {
            val idle = NotificationChannel(
                CHANNEL_IDLE,
                "SIP keep-alive",
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Shown while connected to your SIP server"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(idle)
        }

        // Active call — LOW (not HIGH) so we don't pop a heads-up over the
        // app. If an old build registered the channel at HIGH, drop and
        // recreate so the user's "do not pop up" preference takes effect.
        nm.getNotificationChannel(CHANNEL_CALL)?.let { existing ->
            if (existing.importance > NotificationManager.IMPORTANCE_LOW) {
                nm.deleteNotificationChannel(CHANNEL_CALL)
            } else {
                return
            }
        }
        val call = NotificationChannel(
            CHANNEL_CALL,
            "Active call",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while a SIP call is active"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(call)
    }
}
