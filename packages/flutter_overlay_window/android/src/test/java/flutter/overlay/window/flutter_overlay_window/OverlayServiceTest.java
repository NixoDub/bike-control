package flutter.overlay.window.flutter_overlay_window;

import static org.junit.Assert.assertEquals;

import android.app.Service;

import org.junit.Test;

public class OverlayServiceTest {
    // Android restarts a sticky service with a null intent after it killed the
    // app's process. There is no overlay request to show then, and reading
    // extras from the null intent crashed the app on every such restart.
    @Test
    public void restartWithoutAnIntentStopsInsteadOfCrashing() {
        OverlayService service = new OverlayService();

        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(null, 0, 1));
    }
}
