package com.rosdie.tempmail

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Channel kecil untuk pembaruan lewat APK (lihat lib/update.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tempmail/app")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "info" -> {
                            @Suppress("DEPRECATION")
                            val pi = packageManager.getPackageInfo(packageName, 0)
                            val code =
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                    pi.longVersionCode
                                } else {
                                    @Suppress("DEPRECATION")
                                    pi.versionCode.toLong()
                                }
                            result.success(
                                mapOf(
                                    "versionName" to (pi.versionName ?: ""),
                                    "versionCode" to code,
                                    "abis" to Build.SUPPORTED_ABIS.toList(),
                                    "sdk" to Build.VERSION.SDK_INT,
                                ),
                            )
                        }
                        // Android 8+: izin "Pasang aplikasi tak dikenal" per aplikasi.
                        "canInstall" -> result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls(),
                        )
                        "openInstallSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    ),
                                )
                            }
                            result.success(null)
                        }
                        // Link dari email dibuka di browser, bukan WebView aplikasi.
                        "openUrl" -> {
                            val url = call.argument<String>("url")
                            val uri = url?.let { Uri.parse(it) }
                            if (uri == null || (uri.scheme != "http" && uri.scheme != "https")) {
                                result.success(false)
                            } else {
                                startActivity(
                                    Intent(Intent.ACTION_VIEW, uri)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                                result.success(true)
                            }
                        }
                        "installApk" -> {
                            val path = call.argument<String>("path")
                            if (path == null) {
                                result.error("ARG", "path kosong", null)
                            } else {
                                val uri = FileProvider.getUriForFile(
                                    this,
                                    "$packageName.updates",
                                    File(path),
                                )
                                val intent = Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_ACTIVITY_NEW_TASK,
                                    )
                                startActivity(intent)
                                result.success(true)
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("NATIVE", e.message, null)
                }
            }
    }
}
