package de.circledev.fluxnews.baselineprofile

import android.content.ComponentName
import android.content.Intent
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
        startActivityAndWait(benchmarkTimelineIntent())
    }

    @Test
    fun timelineScroll() = baselineProfileRule.collect(
        packageName = DEVELOPMENT_PACKAGE,
        includeInStartupProfile = false,
    ) {
        pressHome()
        startActivityAndWait(benchmarkTimelineIntent())

        val uiDevice = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val timeline = requireNotNull(
            uiDevice.wait(
                Until.findObject(By.desc(TIMELINE_DESCRIPTION)),
                TIMELINE_WAIT_MILLIS,
            ),
        ) { "Benchmark Timeline did not become visible." }

        timeline.setGestureMargin(TIMELINE_GESTURE_MARGIN_PX)
        repeat(TIMELINE_SCROLLS) {
            timeline.fling(Direction.DOWN)
            uiDevice.waitForIdle()
        }
    }

    private fun benchmarkTimelineIntent(): Intent =
        Intent(Intent.ACTION_MAIN).apply {
            component = ComponentName(DEVELOPMENT_PACKAGE, BENCHMARK_ACTIVITY)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }

    private companion object {
        const val DEVELOPMENT_PACKAGE = "de.circle_dev.flux_news.native.dev"
        const val BENCHMARK_ACTIVITY =
            "de.circledev.fluxnews.nativeapp.BenchmarkTimelineActivity"
        const val TIMELINE_DESCRIPTION = "Benchmark article timeline"
        const val TIMELINE_WAIT_MILLIS = 5_000L
        const val TIMELINE_SCROLLS = 5
        const val TIMELINE_GESTURE_MARGIN_PX = 48
    }
}
