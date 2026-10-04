package de.circle_dev.flux_news

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import de.circledev.fluxnews.nativeapp.AndroidStoragePaths
import de.circledev.fluxnews.nativeapp.AndroidWidgetConfiguration
import de.circledev.fluxnews.nativeapp.AndroidWidgetConfigurationStore
import de.circledev.fluxnews.nativeapp.AndroidWidgetProjectionReader
import de.circledev.fluxnews.nativeapp.AndroidWidgetReadFilter
import de.circledev.fluxnews.nativeapp.MainActivity
import de.circledev.fluxnews.nativeapp.R
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Kept under the production Flutter component name so placed widgets have the
 * best chance of surviving the native application update.
 */
class FluxNewsWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, widgetIds: IntArray) {
        widgetIds.forEach { updateWidget(context, manager, it) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        updateWidget(context, manager, appWidgetId, newOptions)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val configurations = AndroidWidgetConfigurationStore(context)
        appWidgetIds.forEach(configurations::remove)
        super.onDeleted(context, appWidgetIds)
    }

    companion object {
        fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            appWidgetId: Int,
            optionsOverride: android.os.Bundle? = null,
        ) {
            val configuration = AndroidWidgetConfigurationStore(context).read(appWidgetId)
            val reader = AndroidWidgetProjectionReader(AndroidStoragePaths.create(context).widget)
            val header = reader.header(configuration)
            val layout = layoutFor(manager, appWidgetId, optionsOverride)

            val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                RemoteViews(
                    mapOf(
                        SizeF(110f, 40f) to compactViews(context, configuration, header),
                        SizeF(180f, 40f) to compactViews(context, configuration, header),
                        SizeF(320f, 40f) to compactViews(context, configuration, header),
                        SizeF(110f, 110f) to compactViews(context, configuration, header),
                        SizeF(250f, 110f) to listViews(context, appWidgetId, configuration, header),
                    ),
                )
            } else {
                when (layout) {
                    WidgetLayout.Compact -> compactViews(context, configuration, header)
                    WidgetLayout.List -> listViews(context, appWidgetId, configuration, header)
                }
            }

            manager.updateAppWidget(appWidgetId, views)
            if (layout == WidgetLayout.List || Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                manager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
            }
        }

        private fun compactViews(
            context: Context,
            configuration: AndroidWidgetConfiguration,
            header: de.circledev.fluxnews.nativeapp.AndroidWidgetHeader?,
        ): RemoteViews = RemoteViews(context.packageName, R.layout.flux_news_widget_compact).apply {
            bindHeader(context, this, configuration, header)
            setOnClickPendingIntent(R.id.widget_root, openAppIntent(context))
        }

        private fun listViews(
            context: Context,
            appWidgetId: Int,
            configuration: AndroidWidgetConfiguration,
            header: de.circledev.fluxnews.nativeapp.AndroidWidgetHeader?,
        ): RemoteViews = RemoteViews(context.packageName, R.layout.flux_news_widget).apply {
            bindHeader(context, this, configuration, header)
            val serviceIntent = Intent(context, FluxNewsWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
            setRemoteAdapter(R.id.widget_list, serviceIntent)
            setEmptyView(R.id.widget_list, R.id.widget_empty)
            setPendingIntentTemplate(R.id.widget_list, articleTemplate(context))
            setOnClickPendingIntent(R.id.widget_root, openAppIntent(context))
        }

        private fun bindHeader(
            context: Context,
            views: RemoteViews,
            configuration: AndroidWidgetConfiguration,
            header: de.circledev.fluxnews.nativeapp.AndroidWidgetHeader?,
        ) {
            views.setTextViewText(R.id.widget_title, header?.title ?: context.getString(R.string.widget_all_news))
            views.setTextViewText(R.id.widget_count, (header?.count ?: 0L).toString())
            views.setTextViewText(
                R.id.widget_count_label,
                context.getString(
                    if (configuration.readFilter == AndroidWidgetReadFilter.Unread) {
                        R.string.widget_unread
                    } else {
                        R.string.widget_articles
                    },
                ),
            )
            views.setTextViewText(
                R.id.widget_last_sync,
                header?.lastSuccessfulSyncAt?.let { formatSync(context, it) }
                    ?: context.getString(R.string.widget_waiting_for_sync),
            )
        }

        private fun formatSync(context: Context, raw: String): String {
            val formatted = runCatching {
                DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT)
                    .withZone(ZoneId.systemDefault())
                    .format(Instant.parse(raw))
            }.getOrDefault(raw)
            return context.getString(R.string.widget_last_sync, formatted)
        }

        private fun layoutFor(
            manager: AppWidgetManager,
            appWidgetId: Int,
            optionsOverride: android.os.Bundle?,
        ): WidgetLayout {
            val options = optionsOverride ?: manager.getAppWidgetOptions(appWidgetId)
            val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
            val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
            val shortRow = height in 1 until 150
            return when {
                shortRow -> WidgetLayout.Compact
                width in 1 until 220 -> WidgetLayout.Compact
                else -> WidgetLayout.List
            }
        }

        private fun openAppIntent(context: Context): PendingIntent =
            PendingIntent.getActivity(
                context,
                7300,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        private fun articleTemplate(context: Context): PendingIntent =
            PendingIntent.getActivity(
                context,
                7301,
                Intent(context, MainActivity::class.java).apply {
                    action = ACTION_OPEN_ARTICLE
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )

        const val ACTION_OPEN_ARTICLE = "de.circle_dev.flux_news.action.OPEN_WIDGET_ARTICLE"
        const val EXTRA_ARTICLE_ID = "flux.widget.articleId"

        private enum class WidgetLayout { Compact, List }
    }
}

class FluxNewsWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        return FluxNewsWidgetFactory(applicationContext, widgetId)
    }
}

private class FluxNewsWidgetFactory(
    private val context: Context,
    private val widgetId: Int,
) : RemoteViewsService.RemoteViewsFactory {
    private var rows: de.circledev.fluxnews.nativeapp.AndroidWidgetRows? = null
    private val iconCache = mutableMapOf<Long, android.graphics.Bitmap?>()

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        rows?.close()
        iconCache.clear()
        val configuration = AndroidWidgetConfigurationStore(context).read(widgetId)
        rows = AndroidWidgetProjectionReader(AndroidStoragePaths.create(context).widget).openRows(configuration)
    }

    override fun onDestroy() {
        rows?.close()
        rows = null
        iconCache.clear()
    }

    override fun getCount(): Int = rows?.count ?: 0

    override fun getViewAt(position: Int): RemoteViews {
        val row = rows?.rowAt(position)
            ?: return RemoteViews(context.packageName, R.layout.flux_news_widget_row)

        return RemoteViews(context.packageName, R.layout.flux_news_widget_row).apply {
            setTextViewText(R.id.widget_row_title, row.title)
            setTextViewText(R.id.widget_row_feed, row.feedTitle)
            bindIcon(this, row.feedId, row.feedTitle)
            setOnClickFillInIntent(
                R.id.widget_row,
                Intent().apply {
                    action = FluxNewsWidgetProvider.ACTION_OPEN_ARTICLE
                    putExtra(FluxNewsWidgetProvider.EXTRA_ARTICLE_ID, row.id)
                },
            )
        }
    }

    private fun bindIcon(views: RemoteViews, feedId: Long, feedTitle: String) {
        val nightMode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        val dark = nightMode == Configuration.UI_MODE_NIGHT_YES
        val icon = iconCache.getOrPut(feedId) {
            rows?.iconFile(feedId, dark)?.takeIf(File::isFile)?.let {
                BitmapFactory.decodeFile(it.absolutePath)
            }
        }
        if (icon != null) {
            views.setViewVisibility(R.id.widget_row_icon, View.VISIBLE)
            views.setViewVisibility(R.id.widget_row_initial, View.GONE)
            views.setImageViewBitmap(R.id.widget_row_icon, icon)
        } else {
            views.setViewVisibility(R.id.widget_row_icon, View.GONE)
            views.setViewVisibility(R.id.widget_row_initial, View.VISIBLE)
            views.setTextViewText(R.id.widget_row_initial, feedTitle.trim().take(1).uppercase())
        }
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = rows?.rowAt(position)?.id ?: position.toLong()
    override fun hasStableIds(): Boolean = true
}
