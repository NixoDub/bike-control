package de.jonasbark.accessibility

import android.graphics.Rect
import android.view.KeyEvent
import GlobalAction
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet

object Observable {
    var toService: Listener? = null
    // One per Flutter engine: the overlay engine registers this plugin too,
    // and must not take the events away from the app's engine.
    val fromServiceWindow: MutableSet<Receiver> = CopyOnWriteArraySet()
    val fromServiceKeys: MutableSet<Receiver> = CopyOnWriteArraySet()
    var ignoreHidDevices: Boolean = false
    // Use concurrent set for thread-safe access from AccessibilityService and plugin
    var handledKeys: Set<String> = ConcurrentHashMap.newKeySet()
}

interface Listener {
    fun performTouch(x: Double, y: Double, isKeyDown: Boolean, isKeyUp: Boolean)
    fun performGlobalAction(action: GlobalAction)
}

interface Receiver {
    fun onChange(packageName: String, window: Rect)
    fun onKeyEvent(event: KeyEvent)
}
