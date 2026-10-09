package io.vicifast.vicifast_phone.sip

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives call-action broadcasts fired from CallStyle notifications:
 *
 *  - [ACTION_HANGUP]: from the in-call FGS notification's "Hang up"
 *    chip on an active call.
 *  - [ACTION_REJECT]: from the incoming CallStyle notification's
 *    native "Decline" button. Terminates the call; no activity launch.
 *
 * [ACTION_ANSWER] is deliberately NOT handled here. Answering must bring
 * the in-call Activity to the foreground, and starting an Activity from a
 * BroadcastReceiver is a notification trampoline that Android 12+ blocks
 * (the launch silently no-ops). Answer is instead wired as a getActivity
 * PendingIntent that launches MainActivity directly; MainActivity reads
 * the ACTION_ANSWER intent and calls answer() itself. The constant is
 * kept here as the shared action string for that intent.
 */
class SipCallActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_HANGUP = "io.vicifast.phone.action.HANGUP"
        const val ACTION_ANSWER = "io.vicifast.phone.action.ANSWER"

        /** Proves an ANSWER intent came from our own notification: MainActivity is
         *  exported (launcher), so any app could otherwise send it ACTION_ANSWER. */
        const val EXTRA_TOKEN = "io.vicifast.phone.extra.TOKEN"
        val ANSWER_TOKEN: String = java.util.UUID.randomUUID().toString()
        const val ACTION_REJECT = "io.vicifast.phone.action.REJECT"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_HANGUP -> {
                LinphoneManager.getInstance(context).hangup()
            }
            ACTION_REJECT -> {
                LinphoneManager.getInstance(context).hangup()
            }
        }
    }
}
