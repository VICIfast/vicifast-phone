package io.vicifast.vicifast_phone.sip

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * On device reboot, bring liblinphone up so the previously-provisioned account
 * re-registers and incoming calls work without the user opening the app.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        SipConnectionService.ensureRegistered(context)
        LinphoneManager.getInstance(context).start()
    }
}
