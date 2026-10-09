package io.vicifast.vicifast_phone.sip

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Dart <-> liblinphone.
 *
 * Two channels:
 *  - METHOD_CHANNEL   : commands (register, call, answer, hangup, dtmf, mute, hold)
 *  - EVENT_CHANNEL    : state events (regState, callState, incoming, error)
 *
 * Keep this thin — actual SIP logic lives in [LinphoneManager].
 */
class SipPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "io.vicifast.phone/sip"
        const val EVENT_CHANNEL = "io.vicifast.phone/sip_events"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var appContext: Context
    private var manager: LinphoneManager? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)
        // Register the self-managed PhoneAccount up-front. Without this the
        // very first incoming call's Telecom isIncomingCallPermitted() check
        // races registration and may return false, so the lock-screen ringer
        // never appears.
        SipConnectionService.ensureRegistered(appContext)
        manager = LinphoneManager.getInstance(appContext).also {
            it.onEvent = { event -> eventSink?.success(event) }
        }
    }

    /** onNewToken only fires on rotation, usually before Dart listens, so ask once per start. */
    private fun fetchPushToken(mgr: LinphoneManager) {
        try {
            FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
                Handler(Looper.getMainLooper()).post {
                    mgr.onEvent?.invoke(mapOf("type" to "voipToken", "token" to token, "platform" to "fcm"))
                }
            }
        } catch (t: Throwable) {
            // No usable Firebase config in this build; calls still arrive while the app runs.
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        manager?.onEvent = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val mgr = manager ?: return result.error("NOT_READY", "Linphone not initialized", null)
        try {
            when (call.method) {
                "start" -> {
                    mgr.start(); result.success(null)
                    fetchPushToken(mgr)
                }
                "setAgentStatus" -> {
                    SipForegroundService.updateStatus(call.argument<String>("text") ?: "Connected")
                    result.success(null)
                }
                "stop" -> {
                    mgr.stop(); result.success(null)
                }
                "register" -> {
                    val args = call.arguments as Map<*, *>
                    mgr.register(
                        username = args["username"] as String,
                        password = args["password"] as String,
                        domain = args["domain"] as String,
                        proxy = args["proxy"] as String?,
                        transport = (args["transport"] as String?) ?: "udp",
                        port = (args["port"] as Number?)?.toInt()
                    )
                    result.success(null)
                }
                "unregister" -> {
                    mgr.unregister(); result.success(null)
                }
                "forceRefresh" -> {
                    mgr.forceRefresh(); result.success(null)
                }
                "softReconnect" -> {
                    mgr.softReconnect(); result.success(null)
                }
                "verifyRegistration" -> {
                    mgr.verifyRegistration(); result.success(null)
                }
                "wipeAccount" -> {
                    mgr.wipeAccount(); result.success(null)
                }
                "call" -> {
                    val to = call.argument<String>("to")!!
                    val callId = mgr.placeCall(to)
                    result.success(callId)
                }
                "answer" -> {
                    mgr.answer(); result.success(null)
                }
                "hangup" -> {
                    mgr.hangup(); result.success(null)
                }
                "dtmf" -> {
                    mgr.sendDtmf(call.argument<String>("digit")!![0]); result.success(null)
                }
                "setMute" -> {
                    mgr.setMute(call.argument<Boolean>("muted") ?: false); result.success(null)
                }
                "setHold" -> {
                    mgr.setHold(call.argument<Boolean>("on") ?: false); result.success(null)
                }
                "setSpeaker" -> {
                    mgr.setSpeaker(call.argument<Boolean>("on") ?: false); result.success(null)
                }
                "registrationState" -> result.success(mgr.registrationState())
                "currentCall" -> result.success(mgr.currentCallSnapshot())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("SIP_ERROR", t.message, t.stackTraceToString())
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
