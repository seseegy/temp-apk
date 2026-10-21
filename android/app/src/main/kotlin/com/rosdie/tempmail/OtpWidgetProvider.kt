package com.rosdie.tempmail

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/** Widget "Alamat & OTP". Data diisi dari lib/home_widgets.dart. */
class OtpWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val address = widgetData.getString("address", null)
        val otp = widgetData.getString("otp", null)
        val info = widgetData.getString("otp_info", null)
        val updated = widgetData.getString("updated", null)

        for (id in appWidgetIds) {
            val v = RemoteViews(context.packageName, R.layout.widget_otp)
            v.setTextViewText(R.id.w_address, address ?: "Belum ada alamat aktif")
            v.setTextViewText(R.id.w_otp, otp ?: "— — —")
            v.setTextViewText(
                R.id.w_otp_info,
                info ?: if (address == null) "Buka TempMail untuk membuat alamat" else "Ketuk ⟳ untuk memuat OTP",
            )
            v.setTextViewText(R.id.w_updated, updated?.let { "diperbarui $it" } ?: "")

            val open = HomeWidgetLaunchIntent.getActivity(
                context, MainActivity::class.java, Uri.parse("tempmail://open"),
            )
            v.setOnClickPendingIntent(R.id.w_address, open)
            v.setOnClickPendingIntent(
                R.id.w_otp_box,
                HomeWidgetLaunchIntent.getActivity(
                    context, MainActivity::class.java, Uri.parse("tempmail://otp"),
                ),
            )
            v.setOnClickPendingIntent(
                R.id.w_copy_addr, WidgetCopyReceiver.pendingIntent(context, "address"),
            )
            v.setOnClickPendingIntent(
                R.id.w_copy_otp, WidgetCopyReceiver.pendingIntent(context, "otp"),
            )
            v.setOnClickPendingIntent(
                R.id.w_wait,
                HomeWidgetLaunchIntent.getActivity(
                    context, MainActivity::class.java, Uri.parse("tempmail://wait"),
                ),
            )
            v.setOnClickPendingIntent(
                R.id.w_refresh,
                HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("tempmail://refresh")),
            )
            appWidgetManager.updateAppWidget(id, v)
        }
    }
}
