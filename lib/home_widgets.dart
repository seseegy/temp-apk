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
import 'otp_detect.dart';

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
        if (clearOtp) ..._noItem,
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
        ..._otpItem(code),
        'otp_info': _otpInfo(subject, from, DateTime.now()),
        'updated': _hhmm(DateTime.now()),
      });
      await _refreshWidgets();
    } catch (_) {}
  }

  /// Link verifikasi/login baru diketahui aplikasi → ganti isi kotak widget.
  static Future<void> publishLink(
    String url, {
    String? subject,
    String? from,
  }) async {
    if (!_supported) return;
    try {
      await _save({
        ..._linkItem(url),
        'otp_info': _otpInfo(subject, from, DateTime.now(), link: true),
        'updated': _hhmm(DateTime.now()),
      });
      await _refreshWidgets();
    } catch (_) {}
  }
}

// Kotak di widget menampilkan item terakhir: OTP atau link. Widget membaca
// item_kind/item_value (tombol salin kedua ikut berganti "OTP"/"Link").
const Map<String, String?> _noItem = {
  'item_kind': null,
  'item_value': null,
  'otp': null,
};

Map<String, String?> _otpItem(String code) => {
  'item_kind': 'otp',
  'item_value': code,
  'otp': code,
};

Map<String, String?> _linkItem(String url) => {
  'item_kind': 'link',
  'item_value': url,
  'otp': null,
};

String _otpInfo(
  String? subject,
  String? from,
  DateTime at, {
  bool link = false,
}) => [
  if (link) 'Link verifikasi',
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
  await _save({'otp_info': 'Memuat OTP & link terbaru…'});
  await _refreshWidgets();
  // OTP dan link diambil bersamaan; yang paling baru masuk ditampilkan.
  final results = await Future.wait([
    _latestItem(() => api.otpLatest(ref), link: false),
    _latestItem(() => api.verifyLatest(ref), link: true),
    _inboxOtpItem(ref),
  ]);
  final found = results.whereType<_Item>().toList()
    ..sort((a, b) => b.at.compareTo(a.at));
  final errors = results.whereType<String>().toList();
  if (found.isNotEmpty) {
    final it = found.first;
    await _save({
      ...(it.link ? _linkItem(it.value) : _otpItem(it.value)),
      'otp_info': _otpInfo(it.subject, it.from, it.at, link: it.link),
    });
  } else {
    await _save({
      ..._noItem,
      'otp_info': errors.isEmpty
          ? 'Belum ada email berisi OTP / link'
          : 'Gagal: ${errors.first}',
    });
  }
  await _save({'updated': _hhmm(DateTime.now())});
  await _refreshWidgets();
}

/// Cadangan: OTP yang tidak dikenali server, dideteksi dari email terbaru.
Future<Object?> _inboxOtpItem(String ref) async {
  try {
    final r = await api.messages(ref, limit: 10, fresh: true);
    for (final m in listOf(r, ['messages', 'items']).whereType<Map>()) {
      final hit = messageOtp(m);
      if (hit == null || hit.$2) continue; // yang dikenali server sudah ada
      final age = m['age_seconds'];
      return _Item(
        hit.$1,
        false,
        m['subject']?.toString(),
        m['from']?.toString(),
        age is num
            ? DateTime.now().subtract(Duration(seconds: age.round()))
            : DateTime.now(),
      );
    }
    return null;
  } catch (_) {
    return null;
  }
}

class _Item {
  final String value;
  final bool link;
  final String? subject;
  final String? from;
  final DateTime at;
  _Item(this.value, this.link, this.subject, this.from, this.at);
}

/// _Item bila ada, null bila memang kosong, String bila galat.
Future<Object?> _latestItem(
  Future<dynamic> Function() fetch, {
  required bool link,
}) async {
  try {
    final r = await fetch();
    if (r is! Map) return null;
    final raw = link ? (r['link'] ?? r['url']) : r['otp'];
    final value = raw is Map ? (raw['url'] ?? raw['href']) : raw;
    if (value == null || '$value'.isEmpty) return null;
    final msg = r['message'] is Map ? r['message'] as Map : null;
    final age = msg?['age_seconds'] ?? r['age_seconds'];
    final at = age is num
        ? DateTime.now().subtract(Duration(seconds: age.round()))
        : DateTime.now();
    return _Item(
      '$value',
      link,
      msg?['subject']?.toString(),
      msg?['from']?.toString(),
      at,
    );
  } on ApiException catch (e) {
    // Belum ada OTP/link = bukan galat.
    if (e.status == 404 || e.code.startsWith('NO_')) return null;
    return e.message;
  } catch (e) {
    return '$e';
  }
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
      ..._noItem,
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
