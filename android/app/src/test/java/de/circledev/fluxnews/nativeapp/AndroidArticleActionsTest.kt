package de.circledev.fluxnews.nativeapp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.flux_uniffi.ArticleSummary

class AndroidArticleActionsTest {
    @Test
    fun conditionalOuterSwipeActionIsOmittedWithoutPromotingInnerAction() {
        val configuration = AndroidArticleSwipeConfiguration(
            leading = listOf(
                AndroidArticleSwipeAction.ReadUnread,
                AndroidArticleSwipeAction.Comments,
            ),
            trailing = emptyList(),
        )

        val resolved = AndroidArticleActionPolicy.resolveSwipeSide(
            configuration = configuration,
            side = AndroidArticleSwipeSide.Leading,
            article = article(commentsUrl = ""),
            hasAudio = false,
        )

        assertEquals(AndroidArticleSwipeAction.ReadUnread, resolved.additional)
        assertNull(resolved.full)
        assertEquals(listOf(AndroidArticleSwipeAction.ReadUnread), resolved.visibleActions)
    }

    @Test
    fun validOuterSwipeActionKeepsConfiguredFullSwipeMeaning() {
        val configuration = AndroidArticleSwipeConfiguration(
            leading = listOf(
                AndroidArticleSwipeAction.ReadUnread,
                AndroidArticleSwipeAction.Comments,
            ),
            trailing = emptyList(),
        )

        val resolved = AndroidArticleActionPolicy.resolveSwipeSide(
            configuration = configuration,
            side = AndroidArticleSwipeSide.Leading,
            article = article(commentsUrl = "https://example.test/comments"),
            hasAudio = false,
        )

        assertEquals(AndroidArticleSwipeAction.ReadUnread, resolved.additional)
        assertEquals(AndroidArticleSwipeAction.Comments, resolved.full)
    }

    @Test
    fun mediaSwipeActionsStayUnavailableUntilNativeMediaPhase() {
        val article = article()
        assertFalse(
            AndroidArticleActionPolicy.isSwipeActionAvailable(
                AndroidArticleSwipeAction.ListeningList,
                article,
                hasAudio = true,
            ),
        )
        assertFalse(
            AndroidArticleActionPolicy.isSwipeActionAvailable(
                AndroidArticleSwipeAction.DownloadAudio,
                article,
                hasAudio = true,
            ),
        )
        assertTrue(
            AndroidArticleActionPolicy.isSwipeActionAvailable(
                AndroidArticleSwipeAction.StarUnstar,
                article,
                hasAudio = false,
            ),
        )
    }

    @Test
    fun contextActionsOmitInvalidUrlsButKeepCoreBackedActions() {
        val invalid = article(url = "not a url", commentsUrl = "")
        val actions = AndroidArticleActionPolicy.contextActions(invalid)

        assertTrue(AndroidArticleContextAction.ReadUnread in actions)
        assertTrue(AndroidArticleContextAction.StarUnstar in actions)
        assertTrue(AndroidArticleContextAction.Reader in actions)
        assertTrue(AndroidArticleContextAction.OpenMiniflux in actions)
        assertTrue(AndroidArticleContextAction.SaveToService in actions)
        assertFalse(AndroidArticleContextAction.OpenOriginal in actions)
        assertFalse(AndroidArticleContextAction.Comments in actions)
        assertFalse(AndroidArticleContextAction.CopyLink in actions)
        assertFalse(AndroidArticleContextAction.Share in actions)
    }

    @Test
    fun urlValidationAcceptsOnlyHttpAndHttpsWebUrls() {
        assertTrue(AndroidArticleActionPolicy.validWebUrl("https://example.test/article"))
        assertTrue(AndroidArticleActionPolicy.validWebUrl("http://example.test/article"))
        assertFalse(AndroidArticleActionPolicy.validWebUrl("mailto:test@example.test"))
        assertFalse(AndroidArticleActionPolicy.validWebUrl("javascript:alert(1)"))
        assertFalse(AndroidArticleActionPolicy.validWebUrl("not a url"))
    }

    private fun article(
        url: String = "https://example.test/article",
        commentsUrl: String = "",
    ): ArticleSummary = ArticleSummary(
        id = 1L,
        feedId = 10L,
        categoryId = 20L,
        feedTitle = "Feed",
        title = "Article",
        url = url,
        commentsUrl = commentsUrl,
        publishedAt = "2026-10-01T12:00:00Z",
        isRead = false,
        isStarred = false,
        readingTimeMinutes = 3u,
        preview = "Preview",
        imageUrl = null,
    )
}
