package com.rosdie.tempmail

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/** Widget "Buat cepat": alamat acak per grup, dibuat di latar (Dart). */
class QuickWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        // Alamat baru dari isolate latar: salin di sini (butuh konteks native).
        val pending = widgetData.getString("pending_copy", null)
        if (!pending.isNullOrBlank()) {
            widgetData.edit().remove("pending_copy").apply()
            WidgetCopyReceiver.copy(context, pending, "Alamat")
        }

        val status = widgetData.getString("quick_status", null)
            ?: widgetData.getString("address", null)?.let { "Aktif: $it" }
            ?: "Ketuk jenis domain untuk membuat alamat baru"

        for (id in appWidgetIds) {
            val v = RemoteViews(context.packageName, R.layout.widget_quick)
            v.setTextViewText(R.id.w_q_status, status)
            v.setOnClickPendingIntent(
                R.id.w_q_title,
                HomeWidgetLaunchIntent.getActivity(
                    context, MainActivity::class.java, Uri.parse("tempmail://open"),
                ),
            )
            for ((viewId, group) in listOf(
                R.id.w_q_premium to "premium",
                R.id.w_q_basic to "basic",
                R.id.w_q_standard to "standard",
                R.id.w_q_semua to "semua",
            )) {
                v.setOnClickPendingIntent(
                    viewId,
                    HomeWidgetBackgroundIntent.getBroadcast(
                        context, Uri.parse("tempmail://quick?g=$group"),
                    ),
                )
            }
            appWidgetManager.updateAppWidget(id, v)
        }
    }
}
