package de.circledev.fluxnews.nativeapp

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.flux_uniffi.ListeningListFeed
import uniffi.flux_uniffi.ListeningListItem
import uniffi.flux_uniffi.DownloadOrigin
import uniffi.flux_uniffi.ListeningListSort

internal data class AndroidListeningListState(
    val items: List<ListeningListItem> = emptyList(),
    val feeds: List<ListeningListFeed> = emptyList(),
    val selectedFeedId: Long? = null,
    val sort: ListeningListSort = ListeningListSort.RECENTLY_ADDED,
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
)

internal class AndroidListeningListStore(
    private val coreRuntime: AndroidCoreRuntime,
    private val transferCoordinator: AndroidMediaTransferCoordinator? = null,
) {
    private val mutationMutex = Mutex()
    private val mutableState = kotlinx.coroutines.flow.MutableStateFlow(AndroidListeningListState())
    val state: kotlinx.coroutines.flow.StateFlow<AndroidListeningListState> = mutableState

    @Volatile
    private var sessionGeneration: Long? = null

    fun activateSession(generation: Long?) {
        if (sessionGeneration == generation) return
        sessionGeneration = generation
        mutableState.value = AndroidListeningListState()
    }

    suspend fun reload() {
        val generation = sessionGeneration ?: return
        val requested = mutableState.value
        mutableState.value = requested.copy(isLoading = true, errorMessage = null)

        val result = runCatching {
            coreRuntime.localForGeneration(generation) { core ->
                val feeds = core.listeningListFeeds()
                val selectedFeedId = requested.selectedFeedId
                    ?.takeIf { candidate -> feeds.any { it.feedId == candidate } }
                val items = core.listeningList(
                    feedId = selectedFeedId,
                    sort = requested.sort,
                )
                Triple(feeds, selectedFeedId, items)
            }
        }

        if (sessionGeneration != generation) return
        result.fold(
            onSuccess = { (feeds, selectedFeedId, items) ->
                mutableState.value = mutableState.value.copy(
                    items = items,
                    feeds = feeds,
                    selectedFeedId = selectedFeedId,
                    isLoading = false,
                    errorMessage = null,
                )
            },
            onFailure = {
                mutableState.value = mutableState.value.copy(
                    isLoading = false,
                    errorMessage = "Listening List could not be loaded.",
                )
            },
        )
    }

    suspend fun setFeedId(feedId: Long?) {
        if (mutableState.value.selectedFeedId == feedId) return
        mutableState.value = mutableState.value.copy(selectedFeedId = feedId)
        reload()
    }

    suspend fun setSort(sort: ListeningListSort) {
        if (mutableState.value.sort == sort) return
        mutableState.value = mutableState.value.copy(sort = sort)
        reload()
    }

    suspend fun removeFromListeningList(articleId: Long): Result<Unit> =
        mutate(reconcileTransfers = true) { core ->
            core.removeFromListeningList(articleId = articleId)
        }

    suspend fun requestDownload(enclosureId: Long): Result<Unit> =
        mutate(reconcileTransfers = true) { core ->
            core.requestDownload(enclosureId = enclosureId, origin = DownloadOrigin.MANUAL)
        }

    suspend fun cancelDownload(enclosureId: Long): Result<Unit> =
        mutate(reconcileTransfers = true) { core ->
            core.cancelDownload(enclosureId = enclosureId)
        }

    suspend fun retryDownload(enclosureId: Long): Result<Unit> =
        mutate(reconcileTransfers = true) { core ->
            core.retryDownload(enclosureId = enclosureId)
        }

    suspend fun deleteDownload(enclosureId: Long): Result<Unit> =
        mutate(reconcileTransfers = true) { core ->
            core.requestDownloadDeletion(enclosureId = enclosureId)
        }

    private suspend fun mutate(
        reconcileTransfers: Boolean = false,
        operation: (uniffi.flux_uniffi.Flux) -> Unit,
    ): Result<Unit> = mutationMutex.withLock {
        val generation = sessionGeneration ?: return@withLock Result.failure(
            IllegalStateException("No active Core session."),
        )
        val result = runCatching {
            coreRuntime.localForGeneration(generation) { core -> operation(core) }
        }
        if (result.isSuccess && sessionGeneration == generation) {
            if (reconcileTransfers) {
                transferCoordinator?.reconcileAndSignal(generation)
            }
            reload()
        }
        result
    }
}
