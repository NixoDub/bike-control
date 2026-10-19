package de.jonasbark.swiftcontrol

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Replaces the notification flutter_overlay_window 0.5.0 posts for its
 * foreground service. The package uses the launcher icon as the small icon
 * (drawn by Android as a filled circle), shows a bare title, and points its
 * tap at a class that is not an activity. Re-posting under the same id on the
 * same channel swaps the service's notification in place; the service stays
 * foreground.
 */
object OverlayNotification {
    // Match OverlayConstants.CHANNEL_ID / NOTIFICATION_ID in the package.
    private const val CHANNEL_ID = "Overlay Channel"
    private const val NOTIFICATION_ID = 4579

    /**
     * Returns false while the package's notification is not up yet — the
     * service goes foreground after showOverlay returns — so Dart retries.
     */
    fun style(context: Context, title: String, text: String, channelName: String): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (manager.activeNotifications.none { it.id == NOTIFICATION_ID }) return false

        // The package names its channel "Foreground Service Channel", which is
        // what riders see under the app's notification settings.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existing = manager.getNotificationChannel(CHANNEL_ID)
            if (existing != null && existing.name != channelName) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, channelName, existing.importance),
                )
            }
        }

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        }
        val tap = launch?.let {
            PendingIntent.getActivity(
                context,
                NOTIFICATION_ID,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(tap)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
        return true
    }
}
