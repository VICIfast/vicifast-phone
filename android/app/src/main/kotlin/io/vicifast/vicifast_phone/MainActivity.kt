package io.vicifast.vicifast_phone

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.vicifast.vicifast_phone.sip.LinphoneManager
import io.vicifast.vicifast_phone.sip.SipCallActionReceiver
import io.vicifast.vicifast_phone.sip.SipPlugin
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val APP_CHANNEL = "io.vicifast.phone/app"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyOverLockScreenFlags()
        // After process death Android restores the original launch intent;
        // an Answer in it is long stale and must not answer a new ring.
        if (savedInstanceState == null) handleCallActionIntent(intent)
        // Pre-warm liblinphone Core BEFORE Flutter engine attaches. The
        // singleton is otherwise lazy-initialised on the first JNI hop
        // from Dart's SipController.register(), adding 500ms-1.5s to
        // the first registration window. Starting it here lets DNS
        // resolution + Core's iterate loop be already running by the
        // time the Dart layer fires its first register call. start()
        // is idempotent — safe to call again from SipPlugin later.
        try {
            LinphoneManager.getInstance(applicationContext).start()
        } catch (t: Throwable) {
            // Pre-warm is a perf optimization, not load-bearing — if
            // anything fails here SipPlugin's lazy path will surface
            // the same error during register().
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Re-apply the over-lock-screen flags on every re-entry. setShow*
        // calls in onCreate alone are insufficient when MainActivity is
        // launched in singleTop mode and the activity is already in the
        // task stack — the fullScreenIntent then comes via onNewIntent
        // and the user's lock-screen state may have flipped since the
        // last entry.
        applyOverLockScreenFlags()
        // singleTop: when the Activity is already running, the Answer
        // action from the incoming-call notification arrives here rather
        // than via a fresh onCreate. Update the backing intent so any
        // later getIntent() reads the newest action too.
        setIntent(intent)
        handleCallActionIntent(intent)
    }

    /**
     * Accept the call when MainActivity is launched (or re-entered) by
     * the incoming-call notification's Answer action. Answer is wired as
     * a getActivity PendingIntent (see SipConnectionService) precisely so
     * it launches this Activity DIRECTLY — the old BroadcastReceiver ->
     * startActivity path is a notification trampoline that Android 12+
     * silently drops. We answer here, on the main (Core) thread, and the
     * Dart router lands on /in-call once liblinphone fires Connected.
     */
    private fun handleCallActionIntent(intent: Intent?) {
        if (intent?.action != SipCallActionReceiver.ACTION_ANSWER) return
        // Reopened from Recents, the task's base intent can still be an old
        // Answer; it must never answer whatever happens to be ringing now.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.getStringExtra(SipCallActionReceiver.EXTRA_TOKEN) != SipCallActionReceiver.ANSWER_TOKEN) return
        // Consume it, so a recreated Activity (rotation, process restore)
        // doesn't replay the answer.
        intent.action = null
        intent.removeExtra(SipCallActionReceiver.EXTRA_TOKEN)
        try {
            LinphoneManager.getInstance(applicationContext).answer()
        } catch (t: Throwable) {
            // Non-fatal — the in-app IncomingCallScreen still offers an
            // Accept button if this raced liblinphone's readiness.
        }
    }

    private fun applyOverLockScreenFlags() {
        // Allow the activity to come up OVER the lock screen when
        // launched via the incoming-call full-screen intent. The
        // manifest declares android:showWhenLocked +
        // android:turnScreenOn; the runtime calls below are
        // belt-and-braces for OEMs that don't honour the manifest
        // attributes consistently.
        //
        // We deliberately do NOT call requestDismissKeyguard here.
        // Doing so forced an unlock prompt the moment the full-screen
        // incoming-call UI appeared on a locked phone — agents had to
        // unlock BEFORE they could even tap Answer/Reject. With
        // showWhenLocked alone, the call UI renders over the keyguard
        // and the user can answer / reject / mute / hangup without
        // ever dismissing the lock. They unlock naturally only when
        // they need the rest of the app (e.g. View Lead, navigation).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Attach our native SIP plugin to the platform channel
        flutterEngine.plugins.add(SipPlugin())

        // App-level platform channel: methods that need the Activity
        // context but don't fit the SIP plugin. Currently just
        // moveToBackground (used by PopScope on the call screens to
        // mimic HOME-button behaviour without killing the activity).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveToBackground" -> {
                        // moveTaskToBack(true) sends the activity to
                        // the back of the task stack without finishing
                        // it — same as the user pressing HOME. The
                        // Flutter engine + Dart isolate stay alive so
                        // SipState, AgentState, and listeners survive.
                        // SystemNavigator.pop() (the Flutter built-in)
                        // calls finish() instead, which on many devices
                        // tears down the process and we lose the call
                        // screen + dispo handling on return.
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        // True if the OS exempts us from Doze.
                        // Without this, Android may suspend network
                        // access while the screen is locked,
                        // dropping the SIP NAT binding and incoming
                        // call delivery. Dart reads this on agent
                        // sign-in + Settings open to decide whether
                        // to surface the request prompt or a banner.
                        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            pm.isIgnoringBatteryOptimizations(packageName)
                        } else true
                        result.success(ok)
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        // Direct system prompt: "Allow VICIfast to
                        // always run in background?" — one-tap Allow
                        // adds us to the exemption list. Dart shows
                        // its own context-setting pre-prompt first
                        // (UX_PRINCIPLES — never throw a permission
                        // dialog with no explanation).
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(null)
                    }
                    "canUseFullScreenIntent" -> {
                        // Android 14 (API 34) stopped auto-granting
                        // USE_FULL_SCREEN_INTENT to apps that aren't the
                        // default dialer / calling app. Without it, the
                        // incoming-call full-screen intent is downgraded
                        // to a heads-up notification — the call UI no
                        // longer wakes the screen / shows over the lock
                        // screen, which is exactly issue 6. On <34 the
                        // permission is granted at install time so we
                        // report true. Dart reads this on sign-in +
                        // Settings to decide whether to surface the
                        // grant prompt.
                        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                                as android.app.NotificationManager
                            nm.canUseFullScreenIntent()
                        } else true
                        result.success(ok)
                    }
                    "requestFullScreenIntentPermission" -> {
                        // Deep-link to the per-app "Full screen
                        // notifications" settings screen (API 34+ only).
                        // Returns immediately; Dart polls
                        // canUseFullScreenIntent() on next resume to
                        // detect whether the user granted. Dart shows a
                        // context-setting pre-prompt first (UX_PRINCIPLES
                        // — never throw a permission dialog with no
                        // explanation).
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                Uri.parse("package:$packageName"),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(null)
                    }
                    "canInstallApks" -> {
                        // Android 8+ requires per-app permission to
                        // install APKs. Dart calls this before
                        // downloading to decide whether to prompt the
                        // user into Settings or proceed straight to
                        // download → install.
                        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else true
                        result.success(ok)
                    }
                    "openInstallSettings" -> {
                        // Deep-link to the per-app "Install unknown
                        // apps" settings screen. Returns immediately;
                        // Dart polls canInstallApks() on next resume
                        // to detect whether the user granted.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(null)
                    }
                    "installApk" -> {
                        // Hands the downloaded APK off to the system
                        // package installer. We don't manage the
                        // install UI ourselves — just fire the intent
                        // with a FileProvider URI (mandatory since
                        // Android 7 to avoid file:// URI exposure).
                        // System installer takes over from there.
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("BAD_ARG", "path required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("NO_FILE", "APK not found at $path", null)
                                return@setMethodCallHandler
                            }
                            val authority = "$packageName.fileprovider"
                            val uri = FileProvider.getUriForFile(
                                this@MainActivity,
                                authority,
                                file,
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (t: Throwable) {
                            result.error("INSTALL_FAILED", t.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
