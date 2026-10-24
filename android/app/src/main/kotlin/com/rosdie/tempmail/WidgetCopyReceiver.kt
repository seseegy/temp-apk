package com.rosdie.tempmail

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast
import es.antonborri.home_widget.HomeWidgetPlugin

/** Tombol "Salin" di widget: menyalin data widget ke clipboard (native). */
class WidgetCopyReceiver : BroadcastReceiver() {
    companion object {
        private const val ACTION = "com.rosdie.tempmail.WIDGET_COPY"
        private const val EXTRA_KEY = "key"

        fun pendingIntent(context: Context, key: String): PendingIntent {
            val intent = Intent(context, WidgetCopyReceiver::class.java)
                .setAction(ACTION)
                .setData(Uri.parse("tempmail://copy/$key"))
                .putExtra(EXTRA_KEY, key)
            return PendingIntent.getBroadcast(
                context,
                key.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun copy(context: Context, text: String, label: String) {
            val cm = context.getSystemService(ClipboardManager::class.java) ?: return
            cm.setPrimaryClip(ClipData.newPlainText(label, text))
            // Android 13+ sudah menampilkan konfirmasi salin sendiri.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                Toast.makeText(context, "$label disalin: $text", Toast.LENGTH_SHORT).show()
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val key = intent.getStringExtra(EXTRA_KEY) ?: return
        val data = HomeWidgetPlugin.getData(context)
        val label = when (key) {
            "address" -> "Alamat"
            "item_value" -> if (data.getString("item_kind", null) == "link") "Link" else "OTP"
            else -> "OTP"
        }
        val text = data.getString(key, null)
            ?: if (key == "item_value") data.getString("otp", null) else null
        if (text.isNullOrBlank()) {
            Toast.makeText(context, "Belum ada $label", Toast.LENGTH_SHORT).show()
            return
        }
        copy(context, text, label)
    }
}
