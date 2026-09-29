package us.snakepit.ohmypi

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Notification action buttons (Stop on the Running notification, Approve /
 * Deny / options on approval notifications) land here and are forwarded to
 * the Dart main isolate, which stays alive under the foreground service.
 */
class KeepaliveActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_STOP = "us.snakepit.ohmypi.action.KEEPALIVE_BUTTON_STOP"
        const val ACTION_APPROVAL = "us.snakepit.ohmypi.action.KEEPALIVE_BUTTON_APPROVAL"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val gwId = intent.getStringExtra(MainActivity.EXTRA_GW_ID) ?: return
        when (intent.action) {
            ACTION_STOP -> MainActivity.dartChannel
                ?.invokeMethod("intent", mapOf("type" to "stopTurn", "gwId" to gwId))
            ACTION_APPROVAL -> {
                val requestId = intent.getStringExtra(MainActivity.EXTRA_REQUEST_ID) ?: return
                val action = intent.getStringExtra(MainActivity.EXTRA_ACTION) ?: return
                MainActivity.dartChannel?.invokeMethod(
                    "intent",
                    mapOf(
                        "type" to "approvalAction",
                        "gwId" to gwId,
                        "requestId" to requestId,
                        "action" to action,
                    ),
                )
            }
        }
    }
}
