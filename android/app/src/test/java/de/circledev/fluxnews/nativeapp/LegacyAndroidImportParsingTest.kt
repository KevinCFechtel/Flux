package de.circledev.fluxnews.nativeapp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LegacyAndroidImportParsingTest {
    @Test
    fun accountRequiresBothCredentialFields() {
        assertNull(LegacyAndroidImportParsing.account(mapOf("minifluxURL" to "https://example.test")))
        assertNull(LegacyAndroidImportParsing.account(mapOf("minifluxAPIKey" to "secret")))
        assertNull(
            LegacyAndroidImportParsing.account(
                mapOf("minifluxURL" to "  ", "minifluxAPIKey" to "secret"),
            ),
        )
    }

    @Test
    fun accountTrimsCredentialsAndImportsOnlyCompleteHeadersInIndexOrder() {
        val parsed = LegacyAndroidImportParsing.account(
            mapOf(
                "minifluxURL" to " https://example.test/ ",
                "minifluxAPIKey" to " secret ",
                "customHeadersKey_2" to " X-Second ",
                "customHeadersValue_2" to "two",
                "customHeadersKey_0" to "X-First",
                "customHeadersValue_0" to "one",
                "customHeadersKey_1" to "X-Incomplete",
            ),
        )

        requireNotNull(parsed)
        assertEquals("https://example.test/", parsed.serverUrl)
        assertEquals("secret", parsed.apiKey)
        assertEquals(
            listOf(
                LegacyAndroidHeaderImport("X-First", "one"),
                LegacyAndroidHeaderImport("X-Second", "two"),
            ),
            parsed.customHeaders,
        )
    }
    @Test
    fun settingsPreserveExplicitFalseAndOnlyPositiveFeedOverride() {
        val settings = LegacyAndroidImportParsing.settings(
            mapOf(
                "backgroundSyncIntervalMinutes" to "0",
                "autoDownloadAudioAfterSync" to "false",
                "downloadAudioOnlyOnWifi" to "true",
                "audioDownloadRetentionDays" to "30",
                "feedSettingsOverrides" to """{"42":{"openMinifluxEntry":1},"43":{"openMinifluxEntry":0},"44":{"openMinifluxEntry":true}}""",
            ),
        )
        assertEquals(false, settings.backgroundSyncEnabled)
        assertEquals(false, settings.autoDownloadListeningList)
        assertEquals(true, settings.unmeteredDownloadsOnly)
        assertEquals(30, settings.retentionDays)
        assertEquals(listOf(42L), settings.openInMinifluxFeedIds)
    }

}
