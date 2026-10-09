package de.circledev.fluxnews.nativeapp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidLegacyMigrationNoticeTest {
    @Test
    fun freshInstallNeverShowsMigration() {
        assertFalse(AndroidLegacyMigrationNotice().appliesTo("https://example.test"))
    }

    @Test
    fun migratedAccountShowsPendingStepsWithoutSecrets() {
        val state = AndroidLegacyMigrationNotice(importedServer = "https://example.test")
        assertTrue(state.appliesTo("https://example.test"))
        assertFalse(state.appliesTo("https://another.example.test"))
        assertFalse(state.complete)
        assertEquals(1, state.completedSteps)
        assertEquals(6, state.steps.size)
        assertFalse(state.steps.first { it.title == "Downloads" }.complete)
    }

    @Test
    fun allStagesCompleteOnlyWhenEveryStageMarkerIsSet() {
        val complete = AndroidLegacyMigrationNotice(
            importedServer = "https://example.test",
            settingsComplete = true,
            localComplete = true,
            feedsComplete = true,
            startupComplete = true,
            playbackComplete = true,
            downloadsComplete = true,
            widgetsComplete = true,
        )
        assertTrue(complete.complete)
        assertEquals(6, complete.completedSteps)
        assertTrue(complete.appliesTo("https://example.test"))
        assertFalse(complete.copy(acknowledged = true).appliesTo("https://example.test"))
        assertFalse(complete.copy(feedsComplete = false).complete)
    }
}
