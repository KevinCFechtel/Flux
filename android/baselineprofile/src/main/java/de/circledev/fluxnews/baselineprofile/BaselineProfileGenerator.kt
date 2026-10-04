package de.circledev.fluxnews.baselineprofile

import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {
    @get:Rule
    val baselineProfileRule = BaselineProfileRule()

    @Test
    fun startupAndTimelineScroll() = baselineProfileRule.collect(
        packageName = DEVELOPMENT_PACKAGE,
        includeInStartupProfile = true,
    ) {
        pressHome()
        startActivityAndWait()

        // startActivityAndWait() is the deterministic baseline gate. The timeline path is
        // opportunistic: a developer can generate a richer profile on a device whose
        // development app already has an account, without checking credentials into the repo.
        val uiDevice = androidx.test.uiautomator.UiDevice.getInstance(
            InstrumentationRegistry.getInstrumentation(),
        )
        val timeline = uiDevice.wait(
            Until.findObject(By.desc(TIMELINE_DESCRIPTION)),
            TIMELINE_WAIT_MILLIS,
        )
        if (timeline != null) {
            repeat(TIMELINE_SCROLLS) {
                timeline.setGestureMargin(TIMELINE_GESTURE_MARGIN_PX)
                timeline.fling(Direction.DOWN)
                uiDevice.waitForIdle()
            }
        }
    }

    private companion object {
        const val DEVELOPMENT_PACKAGE = "de.circle_dev.flux_news.native.dev"
        const val TIMELINE_DESCRIPTION = "Article timeline"
        const val TIMELINE_WAIT_MILLIS = 2_000L
        const val TIMELINE_SCROLLS = 4
        const val TIMELINE_GESTURE_MARGIN_PX = 48
    }
}
