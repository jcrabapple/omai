package us.snakepit.ohmypi

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

/**
 * Task F: the Android-native foreground service. It is ONLY a process
 * keep-alive plus the ongoing "Running: <title>" notification; all logic
 * stays in the main Dart isolate, which stays alive because this service
 * keeps the process at foreground priority.
 *
 * Type `dataSync`: the service exists so a live session stream (the agent's
 * turn) can keep flowing while the app is backgrounded, which is exactly the
 * data-sync case. remoteMessaging is for messaging apps replying to
 * notifications; specialUse demands a Play-review justification for a case
 * dataSync already covers. The Android 15 6h/day dataSync budget is fine
 * here: the service only runs while a turn is active and stops when the turn
 * ends, the user taps Stop, or the app returns to the foreground.
 */
class KeepaliveService : Service() {

    companion object {
        const val CHANNEL_RUNNING = "keepalive_running"
        const val CHANNEL_APPROVALS = "approvals"

        const val ACTION_UPDATE = "us.snakepit.ohmypi.action.KEEPALIVE_UPDATE"
        const val ACTION_STOP = "us.snakepit.ohmypi.action.KEEPALIVE_STOP"

        const val NOTIFICATION_ID = 42

        @Volatile var instance: KeepaliveService? = null

        fun intent(context: Context, args: Map<*, *>): Intent =
            Intent(context, KeepaliveService::class.java)
                .setAction(ACTION_UPDATE)
                .putExtra(MainActivity.EXTRA_GW_ID, args["gwId"] as? String ?: "")
                .putExtra("title", args["title"] as? String ?: "Running")
                .putExtra("text", args["text"] as? String ?: "")
    }

    private var lastGwId: String = ""

    override fun onCreate() {
        super.onCreate()
        MainActivity.createNotificationChannels(this)
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val gwId = intent?.getStringExtra(MainActivity.EXTRA_GW_ID) ?: ""
        lastGwId = gwId
        val title = intent?.getStringExtra("title") ?: "Running"
        val text = intent?.getStringExtra("text") ?: ""
        startForegroundCompat(buildNotification(gwId, title, text))
        return START_NOT_STICKY
    }

    /** Warm update straight from the Dart side (no service start needed). */
    fun updateNotification(args: Map<*, *>) {
        val gwId = args["gwId"] as? String ?: ""
        val title = args["title"] as? String ?: "Running"
        val text = args["text"] as? String ?: ""
        val manager = NotificationManagerCompat.from(this)
        manager.notify(NOTIFICATION_ID, buildNotification(gwId, title, text))
    }

    private fun buildNotification(gwId: String, title: String, text: String) =
        NotificationCompat.Builder(this, CHANNEL_RUNNING)
            .setSmallIcon(R.drawable.ic_stat_pi)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openSessionIntent(gwId))
            .addAction(
                NotificationCompat.Action(
                    0,
                    getString(R.string.keepalive_stop),
                    stopPendingIntent(gwId),
                ),
            )
            .build()

    private fun openSessionIntent(gwId: String): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java)
            .putExtra(MainActivity.EXTRA_GW_ID, gwId)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun stopPendingIntent(gwId: String): PendingIntent = PendingIntent.getBroadcast(
        this,
        1,
        Intent(this, KeepaliveActionReceiver::class.java)
            .setAction(KeepaliveActionReceiver.ACTION_STOP)
            .setPackage(packageName)
            .putExtra(MainActivity.EXTRA_GW_ID, gwId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun startForegroundCompat(notification: android.app.Notification) {
        // API 34+: the type must be passed explicitly; below that the manifest
        // value is used (FOREGROUND_SERVICE_TYPE_MANIFEST).
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MANIFEST
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }

    /**
     * Android 15+: the dataSync budget (6h per 24h) ran out. Stop within the
     * grace period and tell Dart, which pauses the controller like any other
     * background.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        endedBySystem()
    }

    @Deprecated("API 35 overload; kept for API 34 devices")
    override fun onTimeout(startId: Int) {
        endedBySystem()
    }

    private fun endedBySystem() {
        val gwId = lastGwId
        stopSelf()
        MainActivity.dartChannel?.invokeMethod(
            "intent",
            mapOf("type" to "keepaliveEnded", "gwId" to gwId),
        )
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
