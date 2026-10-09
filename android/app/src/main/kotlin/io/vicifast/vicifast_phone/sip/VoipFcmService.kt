package io.vicifast.vicifast_phone.sip

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives high-priority FCM data messages that wake the app from doze when an
 * incoming SIP call is pending. The actual INVITE arrives over the SIP socket
 * once liblinphone resumes — FCM is purely a wake-up signal here.
 *
 * Expected payload from the server-side push gateway:
 *   { "type": "incoming_call", "from": "+1555...", "call_id": "..." }
 */
class VoipFcmService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "VicifastFcm"
    }

    override fun onNewToken(token: String) {
        Log.i(TAG, "FCM token refreshed; forwarding to Dart for registration")
        // Forward up the same EventChannel iOS uses for its PushKit token
        // (LinphoneManager.swift setVoipPushToken). Dart's SipController
        // caches it in SipState and AgentController POSTs it to
        // /api/mobile/agent/push-token so the box can wake this device.
        // When the process is headless (FCM started us without the Flutter
        // engine), onEvent is null and this no-ops; the durable FCM token
        // is re-emitted on the next refresh once the engine is attached,
        // and AgentController re-flushes SipState on each fresh login.
        // FCM calls this on a worker thread; Flutter's event sink must be fed on main.
        val mgr = LinphoneManager.getInstance(applicationContext)
        Handler(Looper.getMainLooper()).post {
            mgr.onEvent?.invoke(mapOf("type" to "voipToken", "token" to token, "platform" to "fcm"))
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        Log.i(TAG, "FCM data: ${message.data}")
        val type = message.data["type"]
        if (type == "incoming_call") {
            // onMessageReceived runs on an FCM background thread — marshal
            // the Core start onto the core (main) thread. Touching Core off
            // its thread is an intermittent no-op / crash.
            val mgr = LinphoneManager.getInstance(applicationContext)
            mgr.runOnCoreThread {
                // Make sure liblinphone is running so the SIP INVITE that
                // follows is processed.
                mgr.start()
            }
        }
    }
}
