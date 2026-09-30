package us.snakepit.omai

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Task F: the single app MethodChannel. Everything native the app does lives
 * here or in [KeepaliveService]: foreground-service keep-alive, approval
 * notifications, POST_NOTIFICATIONS runtime request, share intent and
 * launcher shortcuts routing.
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL_NAME = "us.snakepit.omai/native"

        const val ACTION_SHORTCUT = "us.snakepit.omai.action.SHORTCUT"

        /** App-private navigation action: notification taps only (review #9). */
        const val ACTION_OPEN_SESSION = "us.snakepit.omai.action.OPEN_SESSION"
        const val EXTRA_ROUTE = "route"
        const val EXTRA_GW_ID = "gwId"
        const val EXTRA_REQUEST_ID = "requestId"
        const val EXTRA_ACTION = "action"

        const val PERMISSION_REQUEST_CODE = 4242

        /** Notification tag so approval ids can never touch the running id. */
        const val TAG_APPROVALS = "approval"

        @Volatile var dartChannel: MethodChannel? = null
        @Volatile private var permissionReply: ((Boolean) -> Unit)? = null

        /** Cold-start intent, held until Dart says it handled it (review #1). */
        @Volatile var pendingLaunchPayload: Map<String, Any?>? = null

        /** Approval notification ids posted but not yet cancelled (review #3). */
        private val openApprovalIds =
            java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

        // Monotonic PendingIntent / notification request codes keyed by
        // requestId (+action): hashCode collisions made Approve fire Deny and
        // let an approval id collide with the running NOTIFICATION_ID
        // (review #7).
        private val requestCodes = HashMap<String, Int>()
        private var nextRequestCode = 10_000

        @Synchronized
        fun requestCodeFor(key: String): Int =
            requestCodes.getOrPut(key) { ++nextRequestCode }

        fun notificationIdFor(requestId: String): Int =
            requestCodeFor("notif:$requestId")

        fun trackApproval(requestId: String) {
            openApprovalIds.add(requestId)
        }

        fun forgetApproval(requestId: String) {
            openApprovalIds.remove(requestId)
        }

        fun createNotificationChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(
                    KeepaliveService.CHANNEL_RUNNING,
                    "Running sessions",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shown while a session's turn runs in the background"
                    setShowBadge(false)
                },
            )
            manager.createNotificationChannel(
                NotificationChannel(
                    KeepaliveService.CHANNEL_APPROVALS,
                    "Needs you",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Sessions waiting on an approval"
                },
            )
        }

        /**
         * The FlutterActivity OWNS its engine: when it is destroyed the Dart
         * isolate dies with it, so the keep-alive cannot outlive the engine
         * and must not pretend to (review #3). Called with the engine gone:
         * stop the service and cancel every Omai notification, so no dead
         * Approve / Stop buttons stay in the drawer.
         */
        fun tearDownKeepalive(context: Context) {
            dartChannel = null
            context.stopService(Intent(context, KeepaliveService::class.java))
            val nm = NotificationManagerCompat.from(context)
            nm.cancel(KeepaliveService.NOTIFICATION_ID)
            for (id in openApprovalIds.toList()) {
                nm.cancel(TAG_APPROVALS, notificationIdFor(id))
                openApprovalIds.remove(id)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        dartChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Every branch replies exactly once: a MethodChannel call
                // that never replies leaves the Dart await hanging forever.
                "requestNotificationPermission" ->
                    requestNotificationPermission { granted -> result.success(granted) }
                "startKeepalive" -> result.success(startKeepalive(call.arguments as? Map<*, *>))
                "updateKeepalive" -> result.success(updateKeepalive(call.arguments as? Map<*, *>))
                "stopKeepalive" -> { stopKeepalive(); result.success(null) }
                "showApproval" -> { showApproval(call.arguments as? Map<*, *>); result.success(null) }
                "cancelApproval" -> { cancelApproval(call.arguments as? Map<*, *>); result.success(null) }
                "getInitialIntent" -> {
                    // Not consumed here: Dart acknowledges with
                    // launchHandled after it has dispatched or queued the
                    // payload (review #1).
                    result.success(pendingLaunchPayload)
                }
                "launchHandled" -> {
                    pendingLaunchPayload = null
                    result.success(null)
                }
                "getAppVersion" -> {
                    // PackageManager info for the About page; longVersionCode
                    // on API 28+, the legacy versionCode widened before that.
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val code =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION")
                            info.versionCode.toLong()
                        }
                    result.success(
                        mapOf("versionName" to (info.versionName ?: ""), "versionCode" to code)
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The engine (and the Dart isolate with it) is going away: the
        // service has nothing left to keep alive and the notification
        // buttons would be dead (review #3).
        tearDownKeepalive(this)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // ------------------------------------------------------------ lifecycle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels(this)
        intentToPayload(intent)?.let { pendingLaunchPayload = it }
    }

    override fun onDestroy() {
        if (isFinishing) tearDownKeepalive(this)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val payload = intentToPayload(intent) ?: return
        // Warm start: straight to Dart. The engine is alive, the channel works.
        dartChannel?.invokeMethod("intent", payload)
    }

    /** Maps a launch intent to the Dart routing payload; null when not ours. */
    private fun intentToPayload(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        // Restored from the Recents screen: the original launch intent comes
        // back again, and re-running an old share or shortcut would be
        // wrong (review #15).
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) {
            return null
        }
        if (intent.action == ACTION_OPEN_SESSION) {
            // Notification tap: open the app on that session. The action is
            // app-private so third-party apps cannot spoof navigation with
            // a bare EXTRA_GW_ID (review #9).
            val gwId = intent.getStringExtra(EXTRA_GW_ID) ?: return null
            return mapOf("type" to "openSession", "gwId" to gwId)
        }
        val shared = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (intent.action == Intent.ACTION_SEND &&
            intent.type == "text/plain" &&
            !shared.isNullOrBlank()
        ) {
            return mapOf("type" to "newSession", "prompt" to shared)
        }
        if (intent.action == ACTION_SHORTCUT) {
            return when (intent.getStringExtra(EXTRA_ROUTE)) {
                "new_session" -> mapOf("type" to "newSession")
                "needs_you" -> mapOf("type" to "needsYou")
                else -> null
            }
        }
        return null
    }

    // ----------------------------------------------------------- Dart calls

    /**
     * Replies exactly once. Prompts only while this activity is resumed (a
     * runtime dialog can't be shown from the background); from the
     * background it just reports the current grant.
     */
    private fun requestNotificationPermission(reply: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            reply(true)
            return
        }
        if (ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            reply(true)
            return
        }
        if (!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
            reply(false)
            return
        }
        permissionReply?.invoke(false) // a superseded request must not hang
        permissionReply = reply
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionReply?.invoke(granted)
        permissionReply = null
    }

    /**
     * False when Android refuses the foreground-service start (background
     * start restrictions, API 31+) so Dart falls back to the plain pause
     * instead of believing the socket is being kept alive.
     */
    private fun startKeepalive(args: Map<*, *>?): Boolean {
        if (args == null) return false
        return try {
            ContextCompat.startForegroundService(this, KeepaliveService.intent(this, args))
            true
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+) extends it.
            false
        } catch (e: SecurityException) {
            false
        }
    }

    private fun updateKeepalive(args: Map<*, *>?): Boolean {
        if (args == null) return false
        val running = KeepaliveService.instance ?: return false
        running.updateNotification(args)
        return true
    }

    private fun stopKeepalive() {
        // stopService also cancels a start that is still in flight, where
        // KeepaliveService.instance is not set yet; stopSelf alone would
        // leak the freshly started service (review #5).
        stopService(Intent(this, KeepaliveService::class.java))
    }

    private fun showApproval(args: Map<*, *>?) {
        if (args == null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        createNotificationChannels(this)
        val requestId = args["requestId"] as? String ?: return
        val gwId = args["gwId"] as? String ?: return
        val actions = (args["actions"] as? List<*>) ?: emptyList<Any?>()

        val open = PendingIntent.getActivity(
            this,
            requestCodeFor("$requestId:open"),
            Intent(this, MainActivity::class.java)
                .setAction(ACTION_OPEN_SESSION)
                .putExtra(EXTRA_GW_ID, gwId)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = NotificationCompat.Builder(this, KeepaliveService.CHANNEL_APPROVALS)
            .setSmallIcon(R.drawable.ic_stat_pi)
            .setContentTitle(args["title"] as? String ?: "Needs your approval")
            .setContentText(args["body"] as? String ?: "")
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(args["body"] as? String ?: ""),
            )
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)

        for (raw in actions) {
            val map = raw as? Map<*, *> ?: continue
            val actionId = map["id"] as? String ?: continue
            val label = map["label"] as? String ?: continue
            val intent = Intent(this, KeepaliveActionReceiver::class.java)
                .setAction(KeepaliveActionReceiver.ACTION_APPROVAL)
                .setPackage(packageName)
                .putExtra(EXTRA_GW_ID, gwId)
                .putExtra(EXTRA_REQUEST_ID, requestId)
                .putExtra(EXTRA_ACTION, actionId)
            val pi = PendingIntent.getBroadcast(
                this,
                // Monotonic per (requestId, action): hashCode collisions let
                // Approve overwrite Deny (review #7).
                requestCodeFor("$requestId:$actionId"),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(NotificationCompat.Action(0, label, pi))
        }

        trackApproval(requestId)
        try {
            // Tagged + monotonic id: never the running service's
            // NOTIFICATION_ID, whatever requestId hashes to (review #7).
            NotificationManagerCompat.from(this)
                .notify(TAG_APPROVALS, notificationIdFor(requestId), builder.build())
        } catch (_: SecurityException) {
            // Permission dropped between check and post; the app UI still works.
        }
    }

    private fun cancelApproval(args: Map<*, *>?) {
        val requestId = args?.get("requestId") as? String ?: return
        forgetApproval(requestId)
        NotificationManagerCompat.from(this)
            .cancel(TAG_APPROVALS, notificationIdFor(requestId))
    }
}
