// Pembaruan aplikasi lewat APK dari GitHub Releases.
//
// - Versi terpasang: APP_BUILD (nomor run CI, disuntik --dart-define) +
//   versionCode/ABI dari native.
// - Versi terbaru: GitHub API (daftar release), jatuh ke redirect
//   /releases/latest bila API gagal (mis. kena limit).
// - Unduhan: berjalan di latar (foreground service via Notifier), bisa
//   dijeda / dilanjutkan (HTTP Range) / dibatalkan, status jelas
//   (mengunduh / dijeda / gagal / siap dipasang), diverifikasi ukuran +
//   SHA-256 bila tersedia, lalu dipasang lewat installer Android.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart';
import 'notify.dart';
import 'screens_main.dart' show fmtTime;

const int kAppBuild = int.fromEnvironment('APP_BUILD');
const String kUpdateRepo = String.fromEnvironment(
  'UPDATE_REPO',
  defaultValue: 'seseegy/temp-apk',
);

const _channel = MethodChannel('tempmail/app');

/// "b12" / "v1.2.0+12" → 12.
int? buildFromTag(String tag) {
  final m = RegExp(r'(\d+)$').firstMatch(tag.trim());
  return m == null ? null : int.tryParse(m[1]!);
}

/// Pilih APK yang cocok dengan ABI perangkat (split-per-abi), lalu universal.
Map? pickApkAsset(List assets, List<String> abis) {
  final apks = assets
      .whereType<Map>()
      .where((a) => '${a['name']}'.toLowerCase().endsWith('.apk'))
      .toList();
  for (final abi in abis) {
    for (final a in apks) {
      if ('${a['name']}'.contains(abi)) return a;
    }
  }
  for (final a in apks) {
    final n = '${a['name']}';
    if (!n.contains('arm') && !n.contains('x86')) return a;
  }
  return apks.isEmpty ? null : apks.first;
}

String fmtBytes(num? b) {
  if (b == null) return '?';
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

class ReleaseInfo {
  final String tag;
  final int build;
  final String name;
  final String notes;
  final DateTime? published;
  final String url;
  final String assetName;
  final int? size;
  final String? sha256;
  final String htmlUrl;
  const ReleaseInfo({
    required this.tag,
    required this.build,
    required this.name,
    required this.notes,
    required this.published,
    required this.url,
    required this.assetName,
    required this.size,
    required this.sha256,
    required this.htmlUrl,
  });

  Map<String, dynamic> toJson() => {
    'tag': tag,
    'build': build,
    'name': name,
    'notes': notes,
    'published': published?.toIso8601String(),
    'url': url,
    'assetName': assetName,
    'size': size,
    'sha256': sha256,
    'htmlUrl': htmlUrl,
  };

  static ReleaseInfo? fromJson(Map m) {
    try {
      return ReleaseInfo(
        tag: m['tag'] as String,
        build: (m['build'] as num).toInt(),
        name: (m['name'] ?? '') as String,
        notes: (m['notes'] ?? '') as String,
        published: DateTime.tryParse('${m['published']}'),
        url: m['url'] as String,
        assetName: (m['assetName'] ?? '') as String,
        size: (m['size'] as num?)?.toInt(),
        sha256: m['sha256'] as String?,
        htmlUrl: (m['htmlUrl'] ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }
}

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  paused,
  failed,
  verifying,
  downloaded,
}

class UpdateService extends ChangeNotifier {
  UpdateService._({
    this.apiBase = 'https://api.github.com',
    this.webBase = 'https://github.com',
    this.repo = kUpdateRepo,
    Directory? dir,
    int? currentBuild,
  }) : _dirOverride = dir,
       _buildOverride = currentBuild;
  static final instance = UpdateService._();

  /// Instans terpisah untuk tes (server tiruan, folder sementara).
  @visibleForTesting
  factory UpdateService.forTest({
    required String apiBase,
    required String webBase,
    required String repo,
    required Directory dir,
    int? currentBuild,
  }) => UpdateService._(
    apiBase: apiBase,
    webBase: webBase,
    repo: repo,
    dir: dir,
    currentBuild: currentBuild,
  );

  final String apiBase;
  final String webBase;
  final String repo;
  final Directory? _dirOverride;
  final int? _buildOverride;

  UpdateStatus status = UpdateStatus.idle;
  ReleaseInfo? release;
  String? checkError; // gagal memeriksa versi
  String? downloadError; // gagal mengunduh / memverifikasi
  DateTime? lastCheck;
  int received = 0;
  int? total;
  double speed = 0; // byte/detik

  String versionName = '';
  int versionCode = 0;
  List<String> abis = const ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'tempmail-android-updater';
  StreamSubscription<List<int>>? _sub;
  Completer<void>? _done;
  String? _stopReason; // 'pause' | 'cancel'
  Timer? _watchdog;
  DateTime _lastUi = DateTime(0);
  DateTime _speedAt = DateTime.now();
  int _speedBytes = 0;
  bool _inited = false;

  /// Build terpasang (null = build lokal tanpa APP_BUILD → tidak bisa
  /// dibandingkan).
  int? get currentBuild => _buildOverride ?? (kAppBuild > 0 ? kAppBuild : null);

  bool get busy =>
      status == UpdateStatus.downloading || status == UpdateStatus.verifying;

  /// Ada sesuatu yang layak ditampilkan di banner Beranda.
  /// Banner Beranda yang ditutup pengguna (per rilis + status).
  String? _dismissed;
  String get _bannerKey => '${release?.tag}:${status.name}';

  void dismissBanner() {
    _dismissed = _bannerKey;
    notifyListeners();
  }

  /// Banner tampil bila ada kabar & belum ditutup (unduhan berjalan selalu
  /// tampil supaya progresnya terlihat).
  bool get showBanner =>
      hasNews &&
      (status == UpdateStatus.downloading ||
          status == UpdateStatus.verifying ||
          _dismissed != _bannerKey);

  bool get hasNews => switch (status) {
    UpdateStatus.available ||
    UpdateStatus.downloading ||
    UpdateStatus.paused ||
    UpdateStatus.failed ||
    UpdateStatus.verifying ||
    UpdateStatus.downloaded => true,
    _ => false,
  };

  double? get progress =>
      total == null || total == 0 ? null : (received / total!).clamp(0.0, 1.0);

  int? get percent => progress == null ? null : (progress! * 100).floor();

  void _set(UpdateStatus s) {
    status = s;
    notifyListeners();
  }

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    Notifier.instance.addListener(_onNotifAction);
    if (Platform.isAndroid) {
      try {
        final info = await _channel.invokeMapMethod<String, dynamic>('info');
        versionName = '${info?['versionName'] ?? ''}';
        versionCode = (info?['versionCode'] as num?)?.toInt() ?? 0;
        final a = (info?['abis'] as List?)?.map((e) => '$e').toList();
        if (a != null && a.isNotEmpty) abis = a;
      } catch (_) {}
    }
    await _restore();
    // Periksa diam-diam saat aplikasi dibuka.
    unawaited(check(silent: true));
  }

  void _onNotifAction(String action, String payload) {
    switch (action) {
      case 'upd_pause':
        pause();
      case 'upd_resume':
        download();
      case 'upd_cancel':
        cancel();
    }
  }

  // ---------------- file lokal ----------------

  Future<Directory> _dir() async {
    final d =
        _dirOverride ??
        Directory('${(await getTemporaryDirectory()).path}/updates');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<File> _apk(ReleaseInfo r) async =>
      File('${(await _dir()).path}/tempmail-${r.tag}.apk');

  Future<File> _part(ReleaseInfo r) async =>
      File('${(await _apk(r)).path}.part');

  Future<File> _meta(ReleaseInfo r) async =>
      File('${(await _apk(r)).path}.json');

  @visibleForTesting
  Future<void> restoreForTest() => _restore();

  /// Pulihkan unduhan yang tertinggal (aplikasi ditutup saat mengunduh).
  Future<void> _restore() async {
    try {
      final dir = await _dir();
      ReleaseInfo? best;
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.apk.json')) continue;
        final r = ReleaseInfo.fromJson(jsonDecode(f.readAsStringSync()));
        if (r == null) continue;
        final cur = currentBuild;
        if (cur != null && r.build <= cur) {
          // Sudah terpasang: bersihkan sisa unduhan lama.
          await _deleteFiles(r);
          continue;
        }
        if (best == null || r.build > best.build) best = r;
      }
      if (best != null) {
        release = best;
        await _syncLocalState();
      }
    } catch (_) {}
  }

  /// Sesuaikan status dengan file yang ada untuk [release].
  Future<void> _syncLocalState() async {
    final r = release;
    if (r == null) return;
    final apk = await _apk(r);
    final part = await _part(r);
    total = r.size;
    if (apk.existsSync()) {
      received = apk.lengthSync();
      total ??= received;
      _set(UpdateStatus.downloaded);
    } else if (part.existsSync() && part.lengthSync() > 0) {
      received = part.lengthSync();
      _set(UpdateStatus.paused);
    }
  }

  Future<void> _deleteFiles(ReleaseInfo r) async {
    for (final f in [await _apk(r), await _part(r), await _meta(r)]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  // ---------------- cek versi ----------------

  Future<void> check({bool silent = false}) async {
    if (status == UpdateStatus.checking || busy) return;
    final before = status;
    checkError = null;
    _set(UpdateStatus.checking);
    ReleaseInfo? latest;
    final errors = <String>[];
    try {
      latest = await _fromApi();
    } catch (e) {
      errors.add('API: ${_errText(e)}');
    }
    if (latest == null) {
      try {
        latest = await _fromRedirect();
      } catch (e) {
        errors.add('Rilis: ${_errText(e)}');
      }
    }
    lastCheck = DateTime.now();
    if (latest == null) {
      checkError = errors.isEmpty ? 'Belum ada rilis APK' : errors.join('\n');
      // Jangan hilangkan status unduhan yang sedang dijeda/selesai.
      status = switch (before) {
        UpdateStatus.paused ||
        UpdateStatus.failed ||
        UpdateStatus.downloaded => before,
        _ => UpdateStatus.idle,
      };
      notifyListeners();
      return;
    }
    final cur = currentBuild;
    final newer = cur == null || latest.build > cur;
    // Rilis yang sama dengan unduhan tertunda → pertahankan progresnya.
    final same = release?.tag == latest.tag;
    if (!same && release != null) await _deleteFiles(release!);
    release = latest;
    if (!newer) {
      await _deleteFiles(latest);
      received = 0;
      total = null;
      _set(UpdateStatus.upToDate);
      return;
    }
    status = UpdateStatus.available;
    received = 0;
    total = latest.size;
    await _syncLocalState();
    notifyListeners();
  }

  Future<dynamic> _getJson(String url) async {
    final req = await _http.getUrl(Uri.parse(url));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 25));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      String msg = 'HTTP ${res.statusCode}';
      try {
        msg = '${jsonDecode(text)['message'] ?? msg}';
      } catch (_) {}
      throw HttpException(msg);
    }
    return jsonDecode(text);
  }

  /// Rilis terbaru (nomor build terbesar) yang punya APK.
  Future<ReleaseInfo?> _fromApi() async {
    final list = await _getJson('$apiBase/repos/$repo/releases?per_page=15');
    ReleaseInfo? best;
    for (final r in (list as List).whereType<Map>()) {
      if (r['draft'] == true || r['prerelease'] == true) continue;
      final tag = '${r['tag_name'] ?? ''}';
      final build = buildFromTag(tag);
      final asset = pickApkAsset((r['assets'] as List?) ?? const [], abis);
      if (build == null || asset == null) continue;
      if (best != null && best.build >= build) continue;
      final digest = '${asset['digest'] ?? ''}';
      best = ReleaseInfo(
        tag: tag,
        build: build,
        name: '${r['name'] ?? tag}',
        notes: '${r['body'] ?? ''}'.trim(),
        published: DateTime.tryParse('${r['published_at']}'),
        url: '${asset['browser_download_url']}',
        assetName: '${asset['name']}',
        size: (asset['size'] as num?)?.toInt(),
        sha256: digest.startsWith('sha256:') ? digest.substring(7) : null,
        htmlUrl: '${r['html_url'] ?? ''}',
      );
    }
    return best;
  }

  /// Cadangan tanpa API: `github.com/<repo>/releases/latest` → redirect ke tag.
  Future<ReleaseInfo?> _fromRedirect() async {
    final req = await _http.getUrl(Uri.parse('$webBase/$repo/releases/latest'));
    req.followRedirects = false;
    final res = await req.close().timeout(const Duration(seconds: 25));
    await res.drain<void>();
    final loc = res.headers.value(HttpHeaders.locationHeader) ?? '';
    final m = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(loc);
    if (m == null) return null;
    final tag = Uri.decodeComponent(m[1]!);
    final build = buildFromTag(tag);
    if (build == null) return null;
    final abi = abis.firstWhere(
      (a) => const ['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains(a),
      orElse: () => 'arm64-v8a',
    );
    final name = 'app-$abi-release.apk';
    return ReleaseInfo(
      tag: tag,
      build: build,
      name: tag,
      notes: '',
      published: null,
      url: '$webBase/$repo/releases/download/$tag/$name',
      assetName: name,
      size: null,
      sha256: null,
      htmlUrl: '$webBase/$repo/releases/tag/$tag',
    );
  }

  String _errText(Object e) {
    if (e is SocketException) return 'tidak ada koneksi';
    if (e is TimeoutException) return 'waktu habis';
    if (e is HttpException) return e.message;
    if (e is FileSystemException) return 'penyimpanan: ${e.message}';
    return '$e';
  }

  // ---------------- unduh ----------------

  Future<void> download() async {
    final r = release;
    if (r == null || busy || status == UpdateStatus.downloaded) return;
    await Notifier.instance.ensurePermission();
    downloadError = null;
    _stopReason = null;
    final part = await _part(r);
    final meta = await _meta(r);
    try {
      meta.writeAsStringSync(jsonEncode(r.toJson()));
    } catch (_) {}
    received = part.existsSync() ? part.lengthSync() : 0;
    total = r.size;
    _speedAt = DateTime.now();
    _speedBytes = received;
    speed = 0;
    _set(UpdateStatus.downloading);
    await Notifier.instance.updateStatus(null);
    await _notifyProgress(force: true);

    IOSink? sink;
    try {
      var res = await _open(r.url, received);
      if (res.statusCode == 416 && r.size != null && received == r.size) {
        await res.drain<void>(); // sudah lengkap
      } else {
        if (res.statusCode == 416 || res.statusCode == 200) {
          // Server tidak mendukung lanjut / file berubah → mulai dari awal.
          if (res.statusCode == 416) {
            await res.drain<void>();
            if (part.existsSync()) part.deleteSync();
            received = 0;
            res = await _open(r.url, 0);
          }
          received = 0;
        }
        if (res.statusCode != 200 && res.statusCode != 206) {
          await res.drain<void>();
          throw HttpException('Server membalas HTTP ${res.statusCode}');
        }
        final len = res.contentLength;
        total = r.size ?? (len > 0 ? received + len : null);
        sink = part.openWrite(
          mode: received > 0 ? FileMode.append : FileMode.write,
        );
        final done = Completer<void>();
        _done = done;
        _kickWatchdog();
        _sub = res.listen(
          (chunk) {
            sink!.add(chunk);
            received += chunk.length;
            _kickWatchdog();
            _tick();
          },
          onError: (Object e) {
            if (!done.isCompleted) done.completeError(e);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
        _watchdog?.cancel();
        await sink.flush();
        await sink.close();
        sink = null;
      }
      if (_stopReason != null) return await _afterStop(r);
      if (total != null && received != total) {
        throw HttpException(
          'Unduhan terputus (${fmtBytes(received)} dari ${fmtBytes(total)})',
        );
      }
      await _verifyAndFinish(r);
    } catch (e) {
      _watchdog?.cancel();
      try {
        await sink?.close();
      } catch (_) {}
      if (_stopReason != null) return await _afterStop(r);
      downloadError = _errText(e);
      _set(UpdateStatus.failed);
      await Notifier.instance.setDownload(null);
      await Notifier.instance.updateStatus(
        'failed',
        title: 'Unduhan pembaruan gagal',
        body:
            '${r.tag}: $downloadError\nTersimpan ${fmtBytes(received)} — "Coba lagi" melanjutkan.',
      );
    } finally {
      _sub = null;
      _done = null;
    }
  }

  /// Buka koneksi dengan Range; redirect diikuti manual supaya header Range
  /// tidak hilang (GitHub mengalihkan ke CDN).
  Future<HttpClientResponse> _open(String url, int from) async {
    var uri = Uri.parse(url);
    for (var i = 0; i < 8; i++) {
      final req = await _http.getUrl(uri);
      req.followRedirects = false;
      req.headers.set('Accept', 'application/octet-stream');
      if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.isRedirect ||
          (res.statusCode >= 300 &&
              res.statusCode < 400 &&
              res.headers.value(HttpHeaders.locationHeader) != null)) {
        final loc = res.headers.value(HttpHeaders.locationHeader)!;
        await res.drain<void>();
        uri = uri.resolve(loc);
        continue;
      }
      return res;
    }
    throw const HttpException('Terlalu banyak pengalihan');
  }

  /// Unduhan macet 30 detik tanpa data → anggap gagal (bisa dicoba lagi).
  void _kickWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 30), () {
      _sub?.cancel();
      final d = _done;
      if (d != null && !d.isCompleted) {
        d.completeError(const HttpException('Koneksi macet, tidak ada data'));
      }
    });
  }

  void _tick() {
    final now = DateTime.now();
    final dt = now.difference(_speedAt).inMilliseconds;
    if (dt >= 1000) {
      speed = (received - _speedBytes) * 1000 / dt;
      _speedAt = now;
      _speedBytes = received;
    }
    if (now.difference(_lastUi).inMilliseconds >= 250) {
      _lastUi = now;
      notifyListeners();
    }
    _notifyProgress();
  }

  DateTime _lastNote = DateTime(0);
  Future<void> _notifyProgress({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastNote).inMilliseconds < 1000) return;
    _lastNote = now;
    final r = release;
    if (r == null) return;
    await Notifier.instance.setDownload(
      DownloadNote('Mengunduh pembaruan ${r.tag}', progressText(), percent),
    );
  }

  /// "45% · 12,3 / 27,1 MB · 1,2 MB/dtk · sisa ~10 dtk"
  String progressText() {
    final parts = <String>[
      if (percent != null) '$percent%',
      '${fmtBytes(received)} / ${fmtBytes(total)}',
    ];
    if (status == UpdateStatus.downloading && speed > 0) {
      parts.add('${fmtBytes(speed)}/dtk');
      if (total != null) {
        final left = ((total! - received) / speed).round();
        parts.add(
          left < 60 ? 'sisa ~$left dtk' : 'sisa ~${(left / 60).ceil()} mnt',
        );
      }
    }
    return parts.join(' · ');
  }

  void pause() {
    if (status != UpdateStatus.downloading) return;
    _stop('pause');
  }

  Future<void> cancel() async {
    final r = release;
    if (busy) {
      _stop('cancel');
      return;
    }
    if (r != null) await _deleteFiles(r);
    received = 0;
    total = r?.size;
    downloadError = null;
    await Notifier.instance.updateStatus(null);
    _set(r == null ? UpdateStatus.idle : UpdateStatus.available);
  }

  void _stop(String reason) {
    _stopReason = reason;
    _watchdog?.cancel();
    _sub?.cancel();
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
  }

  Future<void> _afterStop(ReleaseInfo r) async {
    final reason = _stopReason;
    _stopReason = null;
    await Notifier.instance.setDownload(null);
    if (reason == 'cancel') {
      await _deleteFiles(r);
      received = 0;
      total = r.size;
      await Notifier.instance.updateStatus(null);
      _set(UpdateStatus.available);
    } else {
      _set(UpdateStatus.paused);
      await Notifier.instance.updateStatus(
        'paused',
        title: 'Unduhan pembaruan dijeda',
        body: '${r.tag} · ${progressText()}',
      );
    }
  }

  Future<void> _verifyAndFinish(ReleaseInfo r) async {
    _set(UpdateStatus.verifying);
    final part = await _part(r);
    final expected = r.sha256;
    if (expected != null && expected.isNotEmpty) {
      final path = part.path;
      final got = await Isolate.run(
        () => sha256.convert(File(path).readAsBytesSync()).toString(),
      );
      if (got.toLowerCase() != expected.toLowerCase()) {
        part.deleteSync();
        received = 0;
        throw const HttpException('Checksum SHA-256 tidak cocok, file dihapus');
      }
    }
    final apk = await _apk(r);
    if (apk.existsSync()) apk.deleteSync();
    part.renameSync(apk.path);
    received = apk.lengthSync();
    total = received;
    await Notifier.instance.setDownload(null);
    _set(UpdateStatus.downloaded);
    await Notifier.instance.updateStatus(
      'done',
      title: 'Pembaruan ${r.tag} siap dipasang',
      body:
          'Ketuk "Pasang" untuk memperbarui TempMail (${fmtBytes(received)}).',
    );
  }

  // ---------------- pasang ----------------

  /// null = installer dibuka; 'permission' = perlu izin "Pasang aplikasi
  /// tak dikenal"; selain itu pesan galat.
  Future<String?> install() async {
    final r = release;
    if (r == null || status != UpdateStatus.downloaded) return 'Belum diunduh';
    if (!Platform.isAndroid) return 'Hanya untuk Android';
    try {
      final ok = await _channel.invokeMethod<bool>('canInstall') ?? false;
      if (!ok) return 'permission';
      final apk = await _apk(r);
      if (!apk.existsSync()) {
        _set(UpdateStatus.available);
        return 'File unduhan hilang, unduh ulang';
      }
      await _channel.invokeMethod('installApk', {'path': apk.path});
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {}
  }
}

// ============================ UI ============================

/// Banner kecil di Beranda bila ada pembaruan / unduhan berjalan.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final u = UpdateService.instance;
    return ListenableBuilder(
      listenable: u,
      builder: (ctx, _) {
        if (!u.showBanner || u.release == null) return const SizedBox.shrink();
        final s = Theme.of(ctx).colorScheme;
        final r = u.release!;
        final (IconData icon, String title, String sub) = switch (u.status) {
          UpdateStatus.downloading => (
            Icons.downloading,
            'Mengunduh pembaruan ${r.tag}',
            u.progressText(),
          ),
          UpdateStatus.verifying => (
            Icons.verified_outlined,
            'Memeriksa file ${r.tag}…',
            u.progressText(),
          ),
          UpdateStatus.paused => (
            Icons.pause_circle_outline,
            'Unduhan ${r.tag} dijeda',
            u.progressText(),
          ),
          UpdateStatus.failed => (
            Icons.error_outline,
            'Unduhan ${r.tag} gagal',
            u.downloadError ?? '',
          ),
          UpdateStatus.downloaded => (
            Icons.system_update,
            'Pembaruan ${r.tag} siap dipasang',
            'Ketuk untuk memasang',
          ),
          _ => (
            Icons.system_update_alt,
            'Versi baru tersedia: ${r.tag}',
            r.size == null
                ? 'Ketuk untuk melihat'
                : 'Ukuran ${fmtBytes(r.size)}',
          ),
        };
        final failed = u.status == UpdateStatus.failed;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            color: failed ? s.errorContainer : s.tertiaryContainer,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => openUpdateScreen(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          icon,
                          color: failed
                              ? s.onErrorContainer
                              : s.onTertiaryContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: failed
                                      ? s.onErrorContainer
                                      : s.onTertiaryContainer,
                                ),
                              ),
                              if (sub.isNotEmpty)
                                Text(
                                  sub,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: failed
                                        ? s.onErrorContainer
                                        : s.onTertiaryContainer,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (u.status == UpdateStatus.downloading ||
                            u.status == UpdateStatus.verifying)
                          const Icon(Icons.chevron_right)
                        else
                          IconButton(
                            tooltip: 'Tutup',
                            visualDensity: VisualDensity.compact,
                            onPressed: u.dismissBanner,
                            icon: Icon(
                              Icons.close,
                              color: failed
                                  ? s.onErrorContainer
                                  : s.onTertiaryContainer,
                            ),
                          ),
                      ],
                    ),
                    if (u.status == UpdateStatus.downloading ||
                        u.status == UpdateStatus.paused ||
                        u.status == UpdateStatus.verifying) ...[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: u.status == UpdateStatus.verifying
                            ? null
                            : u.progress,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

void openUpdateScreen({bool autoInstall = false}) {
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  nav.popUntil((r) => r.isFirst);
  nav.push(
    MaterialPageRoute(builder: (_) => UpdateScreen(autoInstall: autoInstall)),
  );
}

class UpdateScreen extends StatefulWidget {
  /// Dibuka dari tombol "Pasang" di notifikasi → langsung buka installer.
  final bool autoInstall;
  const UpdateScreen({super.key, this.autoInstall = false});
  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  final u = UpdateService.instance;

  @override
  void initState() {
    super.initState();
    // Data basi (> 10 menit) → periksa lagi saat layar dibuka.
    final last = u.lastCheck;
    if (widget.autoInstall && u.status == UpdateStatus.downloaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _install());
    } else if (last == null ||
        DateTime.now().difference(last).inMinutes >= 10) {
      u.check();
    }
  }

  /// Batal/hapus membuang bagian yang sudah terunduh → minta konfirmasi.
  Future<void> _confirmCancel() async {
    final done = u.status == UpdateStatus.downloaded;
    if (!done && u.received == 0) return u.cancel();
    final ok = await confirmDialog(
      context,
      title: done ? 'Hapus file unduhan?' : 'Batalkan unduhan?',
      body: done
          ? 'APK ${u.release?.tag ?? ''} yang sudah diunduh akan dihapus.'
          : 'Bagian yang sudah terunduh (${fmtBytes(u.received)}) akan dihapus.',
      confirmLabel: done ? 'Hapus' : 'Batalkan',
    );
    if (ok) await u.cancel();
  }

  Future<void> _install() async {
    final err = await u.install();
    if (!mounted || err == null) return;
    if (err == 'permission') {
      final ok = await confirmDialog(
        context,
        title: 'Izinkan pemasangan',
        body:
            'Android perlu izin "Pasang aplikasi tak dikenal" untuk TempMail. '
            'Aktifkan di layar berikutnya, lalu kembali dan ketuk Pasang lagi.',
        confirmLabel: 'Buka pengaturan',
      );
      if (ok) await u.openInstallSettings();
      return;
    }
    showError(context, err);
  }

  Widget _statusCard(ColorScheme s) {
    final r = u.release;
    final st = u.status;
    Widget chip(String t, Color bg, Color fg, IconData i) => Chip(
      avatar: Icon(i, size: 18, color: fg),
      label: Text(
        t,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700),
      ),
      backgroundColor: bg,
      side: BorderSide.none,
    );
    final List<Widget> body;
    switch (st) {
      case UpdateStatus.checking:
        body = [
          chip(
            'Memeriksa…',
            s.secondaryContainer,
            s.onSecondaryContainer,
            Icons.sync,
          ),
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
        ];
      case UpdateStatus.upToDate:
        body = [
          chip(
            'Sudah versi terbaru',
            s.secondaryContainer,
            s.onSecondaryContainer,
            Icons.check_circle_outline,
          ),
        ];
      case UpdateStatus.available:
        body = [
          chip(
            'Versi baru tersedia',
            s.tertiaryContainer,
            s.onTertiaryContainer,
            Icons.new_releases_outlined,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: u.download,
            icon: const Icon(Icons.download),
            label: Text(
              'Unduh${r?.size != null ? ' (${fmtBytes(r!.size)})' : ''}',
            ),
          ),
        ];
      case UpdateStatus.downloading:
        body = [
          chip(
            'Sedang mengunduh',
            s.primaryContainer,
            s.onPrimaryContainer,
            Icons.downloading,
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: u.progress, minHeight: 6),
          const SizedBox(height: 6),
          Text(u.progressText()),
          Text(
            'Tetap berjalan walau aplikasi ditinggal (lihat notifikasi).',
            style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: u.pause,
                  icon: const Icon(Icons.pause),
                  label: const Text('Jeda'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _confirmCancel,
                  icon: const Icon(Icons.close),
                  label: const Text('Batal'),
                ),
              ),
            ],
          ),
        ];
      case UpdateStatus.paused:
        body = [
          chip(
            'Dijeda',
            s.secondaryContainer,
            s.onSecondaryContainer,
            Icons.pause_circle_outline,
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: u.progress, minHeight: 6),
          const SizedBox(height: 6),
          Text(u.progressText()),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: u.download,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Lanjutkan'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _confirmCancel,
                  icon: const Icon(Icons.close),
                  label: const Text('Batal'),
                ),
              ),
            ],
          ),
        ];
      case UpdateStatus.failed:
        body = [
          chip(
            'Gagal',
            s.errorContainer,
            s.onErrorContainer,
            Icons.error_outline,
          ),
          const SizedBox(height: 8),
          Text(u.downloadError ?? '', style: TextStyle(color: s.error)),
          if (u.received > 0)
            Text(
              'Sudah tersimpan ${u.progressText()} — "Coba lagi" melanjutkan dari sini.',
              style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: u.download,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Coba lagi'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _confirmCancel,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Batal'),
                ),
              ),
            ],
          ),
        ];
      case UpdateStatus.verifying:
        body = [
          chip(
            'Memeriksa file…',
            s.primaryContainer,
            s.onPrimaryContainer,
            Icons.verified_outlined,
          ),
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
        ];
      case UpdateStatus.downloaded:
        body = [
          chip(
            'Siap dipasang',
            s.primaryContainer,
            s.onPrimaryContainer,
            Icons.check_circle,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _install,
            icon: const Icon(Icons.system_update),
            label: const Text('Pasang sekarang'),
          ),
          const SizedBox(height: 6),
          Text(
            'Bila Android menolak ("aplikasi tidak terpasang"), APK ini '
            'ditandatangani dengan kunci berbeda dari yang terpasang.',
            style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
          ),
          TextButton(
            onPressed: _confirmCancel,
            child: const Text('Hapus file unduhan'),
          ),
        ];
      case UpdateStatus.idle:
        body = [
          if (u.checkError != null)
            chip(
              'Gagal memeriksa',
              s.errorContainer,
              s.onErrorContainer,
              Icons.cloud_off,
            )
          else
            chip(
              'Belum diperiksa',
              s.surfaceContainerHighest,
              s.onSurface,
              Icons.help_outline,
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => u.check(),
            icon: const Icon(Icons.refresh),
            label: Text(
              u.checkError != null ? 'Coba lagi' : 'Periksa sekarang',
            ),
          ),
        ];
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: body,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: u,
      builder: (ctx, _) {
        final r = u.release;
        final cur = u.currentBuild;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Pembaruan aplikasi'),
            actions: [
              IconButton(
                tooltip: 'Periksa lagi',
                onPressed: u.status == UpdateStatus.checking || u.busy
                    ? null
                    : () => u.check(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.phone_android),
                      title: Text(
                        cur == null
                            ? 'Terpasang: build lokal'
                            : 'Terpasang: b$cur',
                      ),
                      subtitle: Text(
                        [
                          if (u.versionName.isNotEmpty) 'v${u.versionName}',
                          if (u.abis.isNotEmpty) u.abis.first,
                          if (cur == null) 'tidak bisa dibandingkan',
                        ].join(' · '),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.cloud_outlined),
                      title: Text(
                        r == null
                            ? 'Terbaru: belum diketahui'
                            : 'Terbaru: ${r.tag}',
                      ),
                      subtitle: Text(
                        [
                          if (r?.published != null)
                            'rilis ${fmtTime(r!.published!.toIso8601String())}',
                          if (r?.size != null) fmtBytes(r!.size),
                          if (r != null) r.assetName,
                          if (u.lastCheck != null)
                            'diperiksa ${TimeOfDay.fromDateTime(u.lastCheck!).format(ctx)}',
                        ].join(' · '),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _statusCard(s),
              if (u.checkError != null) ...[
                const SizedBox(height: 12),
                Card(
                  color: s.errorContainer,
                  child: ListTile(
                    leading: Icon(Icons.cloud_off, color: s.onErrorContainer),
                    title: Text(
                      'Gagal memeriksa versi terbaru',
                      style: TextStyle(color: s.onErrorContainer),
                    ),
                    subtitle: Text(
                      u.checkError!,
                      style: TextStyle(color: s.onErrorContainer),
                    ),
                  ),
                ),
              ],
              if (r != null && r.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Catatan rilis',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                SelectableText(r.notes),
              ],
              const SizedBox(height: 16),
              Text(
                'Sumber: github.com/$kUpdateRepo/releases',
                style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}
