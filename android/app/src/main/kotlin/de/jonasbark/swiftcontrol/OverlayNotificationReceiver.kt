package de.jonasbark.swiftcontrol

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Handles the "Hide overlay" button on the gear overlay's notification. */
class OverlayNotificationReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_HIDE = "de.jonasbark.swiftcontrol.HIDE_OVERLAY"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_HIDE) return
        // Normally main Dart hides it and remembers the choice. With no Dart
        // to ask (main engine gone) or no Dart answering, stop the overlay
        // service directly — the same thing the package's closeOverlay does.
        val app = context.applicationContext
        val stopOverlay = {
            app.stopService(
                Intent().setClassName(app, "flutter.overlay.window.flutter_overlay_window.OverlayService"),
            )
            Unit
        }
        if (!OverlayActionBridge.requestHideOverlay(onUnanswered = stopOverlay)) stopOverlay()
    }
}
