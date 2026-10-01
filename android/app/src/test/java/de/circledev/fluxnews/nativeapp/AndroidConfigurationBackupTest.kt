package de.circledev.fluxnews.nativeapp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidConfigurationBackupTest {
    private fun settings() = AndroidBackupSettingsV1(
        hideEmptyNavigationEntries = true,
        startupScope = AndroidStartupScopePreference.Feed.storedValue,
        startupCategoryId = null,
        startupFeedId = 42,
        openArticle = AndroidArticleOpenPreference.Reader.storedValue,
        presentationMode = AndroidArticlePresentationMode.Compact.storedValue,
        previewLines = AndroidArticlePreviewLines.Extended.lineCount,
        showArticleCount = false,
        showRelativePublicationTime = true,
        removeArticlesWhenRead = true,
        markReadOnScrollover = false,
        leadingSwipeFull = AndroidArticleSwipeAction.ReadUnread.storedValue,
        leadingSwipeAdditional = AndroidArticleSwipeAction.Share.storedValue,
        trailingSwipeFull = AndroidArticleSwipeAction.DownloadAudio.storedValue,
        trailingSwipeAdditional = AndroidArticleSwipeAction.ListeningList.storedValue,
        actionBarActions = listOf(
            AndroidActionBarAction.Search.storedValue,
            AndroidActionBarAction.FilterAndSort.storedValue,
        ),
        customHeaders = listOf(StoredCredentialHeader("X-Account", "private")),
    )

    @Test fun payloadRoundTripPreservesNavigationSwipeAndActionOrder() {
        val restored = AndroidBackupSettingsV1.decode(settings().encode())
        assertEquals(settings(), restored)
        assertEquals(42L, restored.startupFeedId)
        assertEquals(listOf("search", "filterAndSort"), restored.actionBarActions)
    }

    @Test fun nonSelectedStartupTargetIsDiscarded() {
        val restored = settings().copy(startupScope = AndroidStartupScopePreference.AllNews.storedValue).validated()
        assertNull(restored.startupCategoryId)
        assertNull(restored.startupFeedId)
    }

    @Test(expected = AndroidConfigurationBackupException.InvalidPlatformSettings::class)
    fun rejectsUnknownSchemaVersion() {
        AndroidBackupSettingsV1.decode(settings().encode().replace("\"version\":1", "\"version\":2"))
    }

    @Test(expected = AndroidConfigurationBackupException.InvalidPlatformSettings::class)
    fun rejectsInvalidStoredEnum() {
        AndroidBackupSettingsV1.decode(settings().copy(openArticle = "invalid").encode())
    }

    @Test(expected = AndroidConfigurationBackupException.InvalidPlatformSettings::class)
    fun rejectsAdditionalSwipeWithoutFullSwipe() {
        AndroidBackupSettingsV1.decode(settings().copy(leadingSwipeFull = null).encode())
    }

    @Test(expected = AndroidConfigurationBackupException.InvalidPlatformSettings::class)
    fun rejectsDuplicateActionBarActions() {
        AndroidBackupSettingsV1.decode(settings().copy(actionBarActions = listOf("search", "search")).encode())
    }
}
