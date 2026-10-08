package de.circledev.fluxnews.nativeapp

import android.content.Intent
import android.support.v4.media.session.MediaSessionCompat
import androidx.annotation.OptIn
import androidx.car.app.CarAppService
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.SessionInfo
import androidx.car.app.annotations.ExperimentalCarApi
import androidx.car.app.media.MediaPlaybackManager
import androidx.car.app.model.CarIcon
import androidx.car.app.model.CarProgressBar
import androidx.car.app.model.Chip
import androidx.car.app.model.ChipSection
import androidx.car.app.model.Header
import androidx.car.app.model.Row
import androidx.car.app.model.RowSection
import androidx.car.app.model.SearchCallback
import androidx.car.app.model.SearchHeader
import androidx.car.app.model.SectionedItemTemplate
import androidx.car.app.model.Template
import androidx.car.app.validation.HostValidator
import androidx.core.graphics.drawable.IconCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.media3.session.MediaConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Development-only Car App Library surface.
 *
 * Production intentionally keeps the stable MediaLibraryService browse UI until templated
 * media apps are generally available for Android Auto distribution.
 */
class FluxCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        HostValidator.ALLOW_ALL_HOSTS_VALIDATOR

    override fun onCreateSession(sessionInfo: SessionInfo): Session =
        FluxCarAppSession()
}

private class FluxCarAppSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen =
        FluxListeningListCarScreen(carContext).also { screen ->
            registerPlaybackTokenWhenAvailable(screen)
        }

    private fun registerPlaybackTokenWhenAvailable(screen: Screen, attempt: Int = 0) {
        val app = carContext.applicationContext as FluxApplication
        val platformToken = app.carAppPlatformToken
        if (platformToken != null) {
            val compatToken = MediaSessionCompat.Token.fromToken(platformToken)
            carContext.getCarService(MediaPlaybackManager::class.java)
                .registerMediaPlaybackToken(compatToken)
            return
        }

        if (attempt >= 20) return
        screen.carContext.mainExecutor.execute {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(
                { registerPlaybackTokenWhenAvailable(screen, attempt + 1) },
                250L,
            )
        }
    }
}

@OptIn(ExperimentalCarApi::class)
private class FluxListeningListCarScreen(
    carContext: CarContext,
) : Screen(carContext), DefaultLifecycleObserver {
    private val app = carContext.applicationContext as FluxApplication
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var snapshot = AndroidAutoMediaLibrarySnapshot()
    private var selectedFeedId: Long? = null
    private var searchText = ""
    private var loading = true

    init {
        lifecycle.addObserver(this)
        reload()
    }

    override fun onDestroy(owner: LifecycleOwner) {
        scope.cancel()
    }

    override fun onGetTemplate(): Template {
        if (loading) {
            return SectionedItemTemplate.Builder()
                .setLoading(true)
                .setHeader(Header.Builder().setTitle("Listening List").build())
                .build()
        }

        val visibleItems = snapshot.items.filter { item ->
            searchText.isBlank() ||
                AndroidAutoMediaLibraryProjection.matchesSearch(item, searchText)
        }

        val rows = visibleItems.map { item ->
            val metadata = item.mediaMetadata
            Row.Builder()
                .setTitle(metadata.title ?: "Untitled News")
                .addText(metadata.artist ?: "Unknown Feed")
                .apply {
                    metadata.artworkUri?.let { uri ->
                        setImage(
                            CarIcon.Builder(IconCompat.createWithContentUri(uri)).build(),
                            Row.IMAGE_TYPE_LARGE,
                        )
                    }
                    metadata.extras
                        ?.takeIf {
                            it.containsKey(MediaConstants.EXTRAS_KEY_COMPLETION_PERCENTAGE)
                        }
                        ?.getDouble(MediaConstants.EXTRAS_KEY_COMPLETION_PERCENTAGE)
                        ?.toFloat()
                        ?.let { progress ->
                            setProgressBar(CarProgressBar.Builder(progress).build())
                        }
                    item.mediaId.toLongOrNull()?.let { enclosureId ->
                        setOnClickListener {
                            scope.launch {
                                app.mediaPlaybackCoordinator.play(enclosureId)
                            }
                        }
                    }
                }
                .build()
        }

        val builder = SectionedItemTemplate.Builder()
        if (carContext.carAppApiLevel >= 9) {
            val chips = buildList {
                add(
                    Chip.Builder()
                        .setTitle("All Feeds")
                        .setSelected(selectedFeedId == null)
                        .setOnClickListener { selectFeed(null) }
                        .build(),
                )
                snapshot.feeds.forEach { feed ->
                    add(
                        Chip.Builder()
                            .setTitle(feed.feedTitle.ifBlank { "Unknown Feed" })
                            .setSelected(selectedFeedId == feed.feedId)
                            .setOnClickListener { selectFeed(feed.feedId) }
                            .build(),
                    )
                }
            }
            if (chips.isNotEmpty()) {
                builder.addSection(ChipSection.Builder().setItems(chips).build())
            }

            builder.setSearchHeader(
                SearchHeader.Builder(
                    object : SearchCallback {
                        override fun onSearchTextChanged(searchText: String) {
                            this@FluxListeningListCarScreen.searchText = searchText
                            invalidate()
                        }

                        override fun onSearchSubmitted(searchText: String) {
                            this@FluxListeningListCarScreen.searchText = searchText
                            invalidate()
                        }
                    },
                )
                    .setInitialSearchText(searchText)
                    .setSearchHint("Search episodes or feeds")
                    .setShowKeyboardByDefault(false)
                    .build(),
            )
        } else {
            builder.setHeader(Header.Builder().setTitle("Listening List").build())
        }

        builder.addSection(
            RowSection.Builder()
                .setItems(rows)
                .setNoItemsMessage(
                    if (searchText.isBlank()) {
                        "No items in the Listening List"
                    } else {
                        "No matching episodes"
                    },
                )
                .build(),
        )

        return builder.build()
    }

    private fun selectFeed(feedId: Long?) {
        if (selectedFeedId == feedId) return
        selectedFeedId = feedId
        reload()
    }

    private fun reload() {
        loading = true
        invalidate()
        scope.launch(Dispatchers.IO) {
            val restored = app.accountBootstrap.restoreStoredAccount()
            val generation = if (restored is AndroidAccountBootstrap.State.Ready) {
                app.coreRuntime.activeSessionGeneration()
            } else {
                null
            }
            val refreshed = if (generation != null) {
                app.autoMediaLibraryStore.refresh(generation, selectedFeedId)
            } else {
                AndroidAutoMediaLibrarySnapshot()
            }

            kotlinx.coroutines.withContext(Dispatchers.Main.immediate) {
                snapshot = refreshed
                selectedFeedId = refreshed.selectedFeedId
                loading = false
                invalidate()
            }
        }
    }
}
