package us.snakepit.omai

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Notification action buttons (Stop on the Running notification, Approve /
 * Deny / options on approval notifications) land here and are forwarded to
 * the Dart main isolate, which stays alive under the foreground service.
 *
 * Review #3: FlutterActivity owns its engine, so a null [MainActivity.dartChannel]
 * means the Dart isolate is gone and the button is dead. Such a notification
 * must not linger as a no-op: it is replaced (approvals) or simply removed
 * (Stop) with an honest plain notification whose tap opens the session in
 * the app. A notification content PendingIntent.getActivity is allowed; a
 * receiver starting an activity is not (the Android 12 trampoline block).
 */
class KeepaliveActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_STOP = "us.snakepit.omai.action.KEEPALIVE_BUTTON_STOP"
        const val ACTION_APPROVAL = "us.snakepit.omai.action.KEEPALIVE_BUTTON_APPROVAL"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val gwId = intent.getStringExtra(MainActivity.EXTRA_GW_ID) ?: return
        when (intent.action) {
            ACTION_STOP -> {
                val channel = MainActivity.dartChannel
                if (channel != null) {
                    channel.invokeMethod(
                        "intent",
                        mapOf("type" to "stopTurn", "gwId" to gwId),
                    )
                } else {
                    // Engine gone: Stop cannot reach Dart. Kill the service
                    // and take its notification down.
                    context.stopService(Intent(context, KeepaliveService::class.java))
                    NotificationManagerCompat.from(context)
                        .cancel(KeepaliveService.NOTIFICATION_ID)
                }
            }
            ACTION_APPROVAL -> {
                val requestId = intent.getStringExtra(MainActivity.EXTRA_REQUEST_ID) ?: return
                val action = intent.getStringExtra(MainActivity.EXTRA_ACTION) ?: return
                val channel = MainActivity.dartChannel
                if (channel != null) {
                    channel.invokeMethod(
                        "intent",
                        mapOf(
                            "type" to "approvalAction",
                            "gwId" to gwId,
                            "requestId" to requestId,
                            "action" to action,
                        ),
                    )
                } else {
                    engineGoneApproval(context, gwId, requestId)
                }
            }
        }
    }

    /** Swap a dead approval for a plain notification that opens the session. */
    private fun engineGoneApproval(context: Context, gwId: String, requestId: String) {
        val nm = NotificationManagerCompat.from(context)
        nm.cancel(MainActivity.TAG_APPROVALS, MainActivity.notificationIdFor(requestId))
        MainActivity.forgetApproval(requestId)
        MainActivity.createNotificationChannels(context)
        val open = PendingIntent.getActivity(
            context,
            MainActivity.requestCodeFor("$requestId:gone-open"),
            Intent(context, MainActivity::class.java)
                .setAction(MainActivity.ACTION_OPEN_SESSION)
                .putExtra(MainActivity.EXTRA_GW_ID, gwId)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, KeepaliveService.CHANNEL_APPROVALS)
            .setSmallIcon(R.drawable.ic_stat_pi)
            .setContentTitle("Omai needs you")
            .setContentText("Open Omai to answer")
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        try {
            nm.notify(
                MainActivity.TAG_APPROVALS,
                MainActivity.notificationIdFor("$requestId:gone"),
                notification,
            )
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS revoked; nothing to fall back to.
        }
    }
}
