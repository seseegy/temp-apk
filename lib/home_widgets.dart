// Widget layar utama Android (native, lihat android/.../widget):
// 1. "Alamat & OTP"  : alamat aktif + OTP terbaru, tombol salin/refresh/tunggu.
// 2. "Buat cepat"    : tombol premium/basic/standard/semua → alamat baru
//                      dibuat di latar dan langsung disalin.
//
// Data dikirim lewat home_widget (SharedPreferences yang dibaca widget).
// Tombol refresh & buat cepat menjalankan [homeWidgetCallback] di isolate
// latar; tombol salin ditangani native (clipboard butuh konteks Android).
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import 'api.dart';
import 'main.dart';

const kOtpWidget = 'OtpWidgetProvider';
const kQuickWidget = 'QuickWidgetProvider';

String _hhmm(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}.${two(l.minute)}';
}

Future<void> _save(Map<String, String?> data) async {
  for (final e in data.entries) {
    await HomeWidget.saveWidgetData<String>(e.key, e.value);
  }
}

Future<void> _refreshWidgets({bool otp = true, bool quick = false}) async {
  if (otp) await HomeWidget.updateWidget(androidName: kOtpWidget);
  if (quick) await HomeWidget.updateWidget(androidName: kQuickWidget);
}

class HomeWidgets {
  static bool _inited = false;
  static String? _lastRef;

  static bool get _supported => Platform.isAndroid;

  /// Dipanggil sekali dari main() setelah frame pertama.
  static Future<void> init() async {
    if (!_supported || _inited) return;
    _inited = true;
    try {
      await HomeWidget.registerInteractivityCallback(homeWidgetCallback);
      HomeWidget.widgetClicked.listen(_handleLaunch);
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (uri != null) _handleLaunch(uri);
      appState.addListener(_onActiveChanged);
      await _onActiveChanged();
    } catch (_) {}
  }

  @visibleForTesting
  static void handleLaunchForTest(Uri? uri) => _handleLaunch(uri);

  /// Aplikasi dibuka dari widget (tombol "Tunggu OTP" / ketuk alamat).
  static void _handleLaunch(Uri? uri) {
    if (uri == null) return;
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    switch (uri.host) {
      case 'wait':
        currentTab.value = kTabOtp;
        otpCommand.value = 'wait';
      case 'otp':
        currentTab.value = kTabOtp;
      default:
        currentTab.value = kTabHome;
    }
  }

  static Future<void> _onActiveChanged() async {
    final ref = appState.activeRef;
    final changed = ref != _lastRef;
    _lastRef = ref;
    await publishActive(
      address: appState.activeAddress,
      ref: ref,
      clearOtp: changed,
    );
  }

  /// Alamat aktif berubah di aplikasi → tampilkan di widget.
  static Future<void> publishActive({
    String? address,
    String? ref,
    bool clearOtp = false,
  }) async {
    if (!_supported) return;
    try {
      await _save({
        'address': address,
        'ref': ref,
        if (clearOtp) 'otp': null,
        if (clearOtp)
          'otp_info': address == null ? null : 'Belum dimuat — ketuk ⟳',
        'updated': _hhmm(DateTime.now()),
      });
      await _refreshWidgets(quick: true);
    } catch (_) {}
  }

  /// OTP baru diketahui aplikasi (terbaru / tunggu / stream).
  static Future<void> publishOtp(
    String code, {
    String? subject,
    String? from,
  }) async {
    if (!_supported) return;
    try {
      await _save({
        'otp': code,
        'otp_info': _otpInfo(subject, from, DateTime.now()),
        'updated': _hhmm(DateTime.now()),
      });
      await _refreshWidgets();
    } catch (_) {}
  }
}

String _otpInfo(String? subject, String? from, DateTime at) => [
  subject,
  from,
  'pukul ${_hhmm(at)}',
].where((e) => e != null && e.trim().isNotEmpty).join(' · ');

/// Dijalankan home_widget di isolate latar saat tombol widget ditekan.
@pragma('vm:entry-point')
Future<void> homeWidgetCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  switch (uri?.host) {
    case 'refresh':
      await _bgRefresh();
    case 'quick':
      await _bgQuick(uri!.queryParameters['g'] ?? 'semua');
  }
}

Future<void> _bgRefresh() async {
  final ref = await HomeWidget.getWidgetData<String>('ref');
  if (ref == null || ref.isEmpty) {
    await _save({'otp_info': 'Belum ada alamat aktif — buka TempMail'});
    return _refreshWidgets();
  }
  await _save({'otp_info': 'Memuat OTP terbaru…'});
  await _refreshWidgets();
  try {
    final r = await api.otpLatest(ref);
    final msg = r is Map && r['message'] is Map ? r['message'] as Map : null;
    final code = r is Map ? r['otp']?.toString() : null;
    final age = msg?['age_seconds'];
    final at = age is num
        ? DateTime.now().subtract(Duration(seconds: age.round()))
        : DateTime.now();
    await _save({
      'otp': code,
      'otp_info': code == null
          ? 'Belum ada email berisi OTP'
          : _otpInfo(msg?['subject']?.toString(), msg?['from']?.toString(), at),
    });
  } on ApiException catch (e) {
    await _save({
      if (e.code == 'NO_OTP' || e.status == 404) 'otp': null,
      'otp_info': e.code == 'NO_OTP' || e.status == 404
          ? 'Belum ada email berisi OTP'
          : 'Gagal: ${e.message}',
    });
  } catch (e) {
    await _save({'otp_info': 'Gagal memuat: $e'});
  }
  await _save({'updated': _hhmm(DateTime.now())});
  await _refreshWidgets();
}

Future<void> _bgQuick(String group) async {
  await _save({'quick_status': 'Membuat alamat $group…'});
  await _refreshWidgets(otp: false, quick: true);
  try {
    final cur = await HomeWidget.getWidgetData<String>('ref');
    final r = await api.quickCreate(
      group,
      exclude: cur == null || cur.isEmpty ? null : [cur],
    );
    final address = '${r['address']}';
    final ref = '${r['ref'] ?? r['saved_as'] ?? address}';
    // Jadikan aktif juga di aplikasi (file state dibaca ulang saat dibuka).
    await appState.setActive(ref, address);
    await _save({
      'address': address,
      'ref': ref,
      'otp': null,
      'otp_info': 'Alamat baru — ketuk ⟳ setelah kirim email',
      'quick_status': 'Disalin: $address',
      // Disalin oleh QuickWidgetProvider (clipboard butuh konteks native).
      'pending_copy': address,
      'updated': _hhmm(DateTime.now()),
    });
  } on ApiException catch (e) {
    await _save({'quick_status': 'Gagal ($group): ${e.message}'});
  } catch (e) {
    await _save({'quick_status': 'Gagal ($group): $e'});
  }
  await _refreshWidgets(quick: true);
}
