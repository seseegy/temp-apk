package com.rosdie.tempmail

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
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
        // Item terakhir: OTP atau link (lib/home_widgets.dart).
        val kind = widgetData.getString("item_kind", null)
        val value = widgetData.getString("item_value", null)
            ?: widgetData.getString("otp", null)
        val isLink = kind == "link" && value != null
        val info = widgetData.getString("otp_info", null)
        val updated = widgetData.getString("updated", null)

        for (id in appWidgetIds) {
            val v = RemoteViews(context.packageName, R.layout.widget_otp)
            v.setTextViewText(R.id.w_address, address ?: "Belum ada alamat aktif")
            v.setTextViewText(R.id.w_otp, if (isLink) "" else value ?: "— — —")
            v.setTextViewText(R.id.w_link, if (isLink) value else "")
            v.setViewVisibility(R.id.w_otp, if (isLink) View.GONE else View.VISIBLE)
            v.setViewVisibility(R.id.w_link, if (isLink) View.VISIBLE else View.GONE)
            v.setTextViewText(R.id.w_copy_otp, if (isLink) "Link" else "OTP")
            v.setTextViewText(
                R.id.w_otp_info,
                info ?: if (address == null) "Buka TempMail untuk membuat alamat" else "Ketuk ⟳ untuk memuat OTP / link",
            )
            v.setTextViewText(R.id.w_updated, updated?.let { "diperbarui $it" } ?: "")

            val open = HomeWidgetLaunchIntent.getActivity(
                context, MainActivity::class.java, Uri.parse("tempmail://open"),
            )
            v.setOnClickPendingIntent(R.id.w_address, open)
            val linkUri = if (isLink) Uri.parse(value) else null
            val boxIntent =
                if (linkUri != null && (linkUri.scheme == "http" || linkUri.scheme == "https")) {
                    // Item link → buka langsung di browser.
                    PendingIntent.getActivity(
                        context,
                        1,
                        Intent(Intent.ACTION_VIEW, linkUri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                } else {
                    HomeWidgetLaunchIntent.getActivity(
                        context, MainActivity::class.java, Uri.parse("tempmail://otp"),
                    )
                }
            v.setOnClickPendingIntent(R.id.w_otp_box, boxIntent)
            v.setOnClickPendingIntent(
                R.id.w_copy_addr, WidgetCopyReceiver.pendingIntent(context, "address"),
            )
            v.setOnClickPendingIntent(
                R.id.w_copy_otp, WidgetCopyReceiver.pendingIntent(context, "item_value"),
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
