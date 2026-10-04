package de.circledev.fluxnews.baselineprofile

import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {
    @get:Rule
    val baselineProfileRule = BaselineProfileRule()

    @Test
    fun startup() = baselineProfileRule.collect(
        packageName = DEVELOPMENT_PACKAGE,
        includeInStartupProfile = true,
    ) {
        pressHome()
        startActivityAndWait()
    }

    @Test
    fun timelineScroll() = baselineProfileRule.collect(
        packageName = DEVELOPMENT_PACKAGE,
        includeInStartupProfile = false,
    ) {
        pressHome()
        startActivityAndWait()

        // A configured account is intentionally not synthesized here. On a clean benchmark app
        // this contributes only the launch path; after the side-by-side benchmark app is configured
        // locally, the same generator records the real Timeline without storing credentials in git.
        val uiDevice = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val timeline = uiDevice.wait(
            Until.findObject(By.desc(TIMELINE_DESCRIPTION)),
            TIMELINE_WAIT_MILLIS,
        )
        if (timeline != null) {
            timeline.setGestureMargin(TIMELINE_GESTURE_MARGIN_PX)
            repeat(TIMELINE_SCROLLS) {
                timeline.fling(Direction.DOWN)
                uiDevice.waitForIdle()
            }
        }
    }

    private companion object {
        const val DEVELOPMENT_PACKAGE = "de.circle_dev.flux_news.native.dev.benchmark"
        const val TIMELINE_DESCRIPTION = "Article timeline"
        const val TIMELINE_WAIT_MILLIS = 2_000L
        const val TIMELINE_SCROLLS = 4
        const val TIMELINE_GESTURE_MARGIN_PX = 48
    }
}
