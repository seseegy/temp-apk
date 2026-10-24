// Notifikasi lokal (Android):
// - status "sedang berjalan" (menunggu OTP / mengunduh pembaruan) sebagai
//   foreground service, supaya proses tetap hidup saat aplikasi ditinggal;
// - OTP masuk;
// - status unduhan pembaruan (dijeda / gagal / siap dipasang).
//
// Semua panggilan plugin dibungkus try/catch: notifikasi gagal tidak boleh
// mengganggu fitur utama.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _portName = 'tempmail.notif.actions';

/// Tombol aksi yang tidak membuka aplikasi dijalankan plugin di isolate
/// latar; teruskan ke isolate utama lewat port bernama.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse r) {
  IsolateNameServer.lookupPortByName(
    _portName,
  )?.send(jsonEncode({'action': r.actionId ?? '', 'payload': r.payload ?? ''}));
}

/// [action] = id tombol ('' bila notifikasinya sendiri yang diketuk).
typedef NotifActionListener = void Function(String action, String payload);

/// Info unduhan untuk notifikasi foreground.
class DownloadNote {
  final String title;
  final String body;
  final int? percent; // null = belum diketahui (indeterminate)
  const DownloadNote(this.title, this.body, this.percent);
}

class Notifier with WidgetsBindingObserver {
  Notifier._();
  static final instance = Notifier._();

  static const _keepAliveId = 7001;
  static const _otpId = 7002;
  static const _updateId = 7003;
  static const _linkId = 7004;

  static const _icon = 'ic_stat_mail';

  final _plugin = FlutterLocalNotificationsPlugin();
  ReceivePort? _port;
  bool _ready = false;
  bool _askedPermission = false;
  bool _serviceRunning = false;
  AppLifecycleState _life = AppLifecycleState.resumed;
  final _listeners = <NotifActionListener>[];

  // Isi notifikasi foreground: daftar hal yang sedang ditunggu + unduhan.
  final Map<String, String> _waiting = {};
  DateTime? _waitingSince;
  DownloadNote? _download;

  bool get inForeground => _life == AppLifecycleState.resumed;

  void addListener(NotifActionListener l) => _listeners.add(l);
  void removeListener(NotifActionListener l) => _listeners.remove(l);

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  Future<void> init() async {
    if (!Platform.isAndroid || _ready) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      final port = ReceivePort();
      IsolateNameServer.removePortNameMapping(_portName);
      IsolateNameServer.registerPortWithName(port.sendPort, _portName);
      port.listen((m) {
        try {
          final d = jsonDecode(m as String) as Map;
          _dispatch('${d['action']}', '${d['payload']}');
        } catch (_) {}
      });
      _port = port;
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(_icon),
        ),
        onDidReceiveNotificationResponse: (r) =>
            _dispatch(r.actionId ?? '', r.payload ?? ''),
        onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
      );
      _ready = true;
      // Aplikasi dibuka dari notifikasi saat prosesnya sudah mati.
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final r = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && r != null) {
        _dispatch(r.actionId ?? '', r.payload ?? '');
      }
    } catch (_) {}
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _port?.close();
    IsolateNameServer.removePortNameMapping(_portName);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _life = state;

  void _dispatch(String action, String payload) {
    for (final l in List.of(_listeners)) {
      try {
        l(action, payload);
      } catch (_) {}
    }
  }

  /// Minta izin notifikasi (Android 13+) sekali per sesi.
  Future<void> ensurePermission() async {
    if (!_ready || _askedPermission) return;
    _askedPermission = true;
    try {
      await _android?.requestNotificationsPermission();
    } catch (_) {}
  }

  // ---------------- foreground: menunggu OTP + unduhan ----------------

  /// [text] null = hal [key] selesai ditunggu.
  Future<void> setWaiting(String key, String? text) async {
    if (text == null) {
      if (_waiting.remove(key) == null) return;
    } else {
      if (_waiting.isEmpty) _waitingSince = DateTime.now();
      _waiting[key] = text;
    }
    if (_waiting.isEmpty) _waitingSince = null;
    await _refreshKeepAlive();
  }

  Future<void> clearWaiting() async {
    if (_waiting.isEmpty) return;
    _waiting.clear();
    _waitingSince = null;
    await _refreshKeepAlive();
  }

  Future<void> setDownload(DownloadNote? note) async {
    _download = note;
    await _refreshKeepAlive();
  }

  Future<void> _refreshKeepAlive() async {
    if (!_ready) return;
    try {
      if (_waiting.isEmpty && _download == null) {
        if (_serviceRunning) {
          _serviceRunning = false;
          await _android?.stopForegroundService();
        }
        await _plugin.cancel(id: _keepAliveId);
        return;
      }
      final String title;
      final String body;
      final AndroidNotificationDetails details;
      final dl = _download;
      if (dl != null) {
        title = dl.title;
        body = dl.body;
        details = AndroidNotificationDetails(
          'status',
          'Proses berjalan',
          channelDescription:
              'Menunggu OTP / mengunduh pembaruan saat aplikasi ditinggal',
          icon: _icon,
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showWhen: false,
          showProgress: true,
          maxProgress: 100,
          progress: dl.percent ?? 0,
          indeterminate: dl.percent == null,
          subText: _waiting.isEmpty ? null : 'Juga menunggu OTP',
          category: AndroidNotificationCategory.progress,
          actions: const [
            AndroidNotificationAction('upd_pause', 'Jeda'),
            AndroidNotificationAction('upd_cancel', 'Batal'),
          ],
        );
      } else {
        title = _waiting.length == 1
            ? 'Menunggu OTP…'
            : 'Menunggu OTP (${_waiting.length} proses)…';
        body = _waiting.values.join('\n');
        details = AndroidNotificationDetails(
          'status',
          'Proses berjalan',
          channelDescription:
              'Menunggu OTP / mengunduh pembaruan saat aplikasi ditinggal',
          icon: _icon,
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          usesChronometer: true,
          showWhen: true,
          when: (_waitingSince ?? DateTime.now()).millisecondsSinceEpoch,
          category: AndroidNotificationCategory.service,
          styleInformation: BigTextStyleInformation(body),
          actions: const [AndroidNotificationAction('wait_stop', 'Berhenti')],
        );
      }
      final payload = jsonEncode({'t': dl != null ? 'update' : 'wait'});
      if (!_serviceRunning) {
        // Dimulai dari aksi pengguna (aplikasi di depan / tombol notifikasi),
        // sehingga diizinkan Android 12+.
        await _android?.startForegroundService(
          id: _keepAliveId,
          title: title,
          body: body,
          notificationDetails: details,
          payload: payload,
          startType: AndroidServiceStartType.startNotSticky,
          foregroundServiceTypes: {
            AndroidServiceForegroundType.foregroundServiceTypeDataSync,
          },
        );
        _serviceRunning = true;
      } else {
        // Perbarui isi notifikasi service yang sudah berjalan (id sama).
        await _plugin.show(
          id: _keepAliveId,
          title: title,
          body: body,
          notificationDetails: NotificationDetails(android: details),
          payload: payload,
        );
      }
    } catch (_) {}
  }

  // ---------------- OTP ----------------

  Future<void> otpArrived(
    String code, {
    String? subject,
    String? from,
    String? address,
  }) async {
    if (!_ready) return;
    final info = [
      subject,
      from,
    ].where((e) => e != null && e.trim().isNotEmpty).join(' · ');
    final body = [
      if (info.isNotEmpty) info,
      if (address != null) 'ke $address',
      'Sudah disalin otomatis',
    ].join('\n');
    try {
      await _plugin.show(
        id: _otpId,
        title: 'OTP $code',
        body: body,
        payload: jsonEncode({'t': 'otp', 'code': code}),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'otp',
            'OTP masuk',
            channelDescription: 'Kode OTP yang baru masuk',
            icon: _icon,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            ticker: 'OTP $code',
            styleInformation: BigTextStyleInformation(body),
            actions: const [
              AndroidNotificationAction(
                'otp_copy',
                'Salin',
                showsUserInterface: true,
              ),
            ],
          ),
        ),
      );
    } catch (_) {}
  }

  /// Link verifikasi / login / reset yang baru masuk (sudah disalin).
  Future<void> linkArrived(
    String url, {
    String? subject,
    String? from,
    String? address,
  }) async {
    if (!_ready) return;
    final host = Uri.tryParse(url)?.host ?? '';
    final info = [
      subject,
      from,
    ].where((e) => e != null && e.trim().isNotEmpty).join(' · ');
    final body = [
      if (info.isNotEmpty) info,
      url,
      if (address != null) 'ke $address',
      'Sudah disalin otomatis',
    ].join('\n');
    try {
      await _plugin.show(
        id: _linkId,
        title: host.isEmpty ? 'Link verifikasi masuk' : 'Link masuk · $host',
        body: body,
        payload: jsonEncode({'t': 'link', 'url': url}),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'link',
            'Link verifikasi masuk',
            channelDescription:
                'Link verifikasi / login / reset yang baru masuk',
            icon: _icon,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            ticker: 'Link verifikasi masuk',
            styleInformation: BigTextStyleInformation(body),
            actions: const [
              AndroidNotificationAction(
                'link_copy',
                'Salin',
                showsUserInterface: true,
              ),
              AndroidNotificationAction(
                'link_open',
                'Buka',
                showsUserInterface: true,
              ),
            ],
          ),
        ),
      );
    } catch (_) {}
  }

  /// Info biasa (mis. waktu tunggu habis) di kanal OTP berprioritas rendah.
  Future<void> otpInfo(String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _otpId,
        title: title,
        body: body,
        payload: jsonEncode({'t': 'wait'}),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'otp_info',
            'Info menunggu OTP',
            channelDescription: 'Mis. waktu tunggu OTP habis',
            icon: _icon,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
      );
    } catch (_) {}
  }

  // ---------------- pembaruan ----------------

  /// Notifikasi status unduhan di luar foreground service.
  /// [kind]: 'paused' | 'failed' | 'done'; null = hapus.
  Future<void> updateStatus(
    String? kind, {
    String title = '',
    String body = '',
  }) async {
    if (!_ready) return;
    try {
      if (kind == null) {
        await _plugin.cancel(id: _updateId);
        return;
      }
      final actions = switch (kind) {
        'paused' => const [
          AndroidNotificationAction('upd_resume', 'Lanjutkan'),
          AndroidNotificationAction('upd_cancel', 'Batal'),
        ],
        'failed' => const [
          AndroidNotificationAction('upd_resume', 'Coba lagi'),
          AndroidNotificationAction('upd_cancel', 'Batal'),
        ],
        _ => const [
          AndroidNotificationAction(
            'upd_install',
            'Pasang',
            showsUserInterface: true,
          ),
        ],
      };
      await _plugin.show(
        id: _updateId,
        title: title,
        body: body,
        payload: jsonEncode({'t': 'update'}),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'update',
            'Pembaruan aplikasi',
            channelDescription: 'Status unduhan pembaruan aplikasi',
            icon: _icon,
            importance: kind == 'done'
                ? Importance.high
                : Importance.defaultImportance,
            priority: kind == 'done' ? Priority.high : Priority.defaultPriority,
            onlyAlertOnce: kind == 'paused',
            autoCancel: kind == 'done',
            styleInformation: BigTextStyleInformation(body),
            actions: actions,
          ),
        ),
      );
    } catch (_) {}
  }
}
