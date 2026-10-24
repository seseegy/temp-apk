// Layar OTP: terbaru, tunggu, tunggu banyak alamat, stream SSE,
// riwayat, uji ekstrak, dan link verifikasi.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'main.dart';
import 'home_widgets.dart';
import 'notify.dart';
import 'otp_detect.dart';
import 'screens_main.dart' show fmtTime;

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});
  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  dynamic _latest;
  String? _latestEmpty; // pesan ramah bila belum ada OTP
  bool _loadingLatest = false;
  int _refGen = 0; // naik saat alamat berganti → request alamat lama diabaikan
  dynamic _waitResult;
  bool _waitStale = false;
  bool _waiting = false;
  int _waitGen = 0; // naik saat "Batal" → hasil tunggu lama diabaikan
  int _waitSecs = 0;
  Timer? _waitTick;
  Timer? _waitPoll; // cek inbox selama menunggu (cadangan deteksi server)
  bool _polling = false;
  final _timeoutCtl = TextEditingController(text: '50');
  final _refsCtl = TextEditingController();
  dynamic _waitAnyResult;
  bool _waitingAny = false;
  int _anyGen = 0; // naik saat dihentikan dari notifikasi
  String _waitAnyMode = 'otp';

  StreamSubscription? _sub;
  final List<String> _streamLog = [];
  bool _streaming = false;

  dynamic _history;
  final _extractCtl = TextEditingController();
  dynamic _extractResult;
  dynamic _verifyLatest;
  dynamic _verifyWait;
  bool _verifyWaiting = false;
  bool _verifyLoading = false;
  int _verifyGen = 0; // naik saat "Tunggu link" dibatalkan
  String? _waitError; // galat/timeout "Tunggu OTP" (pesan ramah, bukan JSON)
  String? _waitAnyError;

  String? _shownRef;

  @override
  void initState() {
    super.initState();
    _shownRef = appState.activeRef;
    appState.addListener(_onState);
    currentTab.addListener(_onTab);
    Notifier.instance.addListener(_onNotif);
    otpCommand.addListener(_onCommand);
  }

  /// Perintah dari widget layar utama ("Tunggu OTP"). Bila alamat aktif
  /// belum termuat (aplikasi baru dibuka), dijalankan saat alamat siap.
  void _onCommand() {
    if (!mounted || otpCommand.value != 'wait' || _ref == null) return;
    otpCommand.value = null;
    if (!_waiting) _wait();
  }

  /// Tombol "Berhenti" di notifikasi status menunggu.
  void _onNotif(String action, String payload) {
    if (action != 'wait_stop' || !mounted) return;
    if (_waiting) _wait();
    if (_streaming) _toggleStream();
    if (_waitingAny) _cancelWaitAny();
    if (_verifyWaiting) _cancelVerifyWait();
  }

  void _cancelWaitAny() {
    _anyGen++;
    Notifier.instance.setWaiting('any', null);
    setState(() => _waitingAny = false);
  }

  void _cancelVerifyWait() {
    _verifyGen++;
    Notifier.instance.setWaiting('link', null);
    setState(() => _verifyWaiting = false);
  }

  String get _addr => appState.activeAddress ?? _ref ?? '';

  /// Notifikasi OTP hanya bila pengguna tidak sedang melihat tab OTP.
  void _notifyOtp(String code, dynamic msg, {String? address}) {
    final m = msg is Map ? msg : const {};
    // Widget layar utama ikut menampilkan OTP alamat aktif.
    if (address == null || address == _addr) {
      HomeWidgets.publishOtp(
        code,
        subject: m['subject']?.toString(),
        from: m['from']?.toString(),
      );
    }
    if (Notifier.instance.inForeground && currentTab.value == kTabOtp) return;
    Notifier.instance.otpArrived(
      code,
      subject: m['subject']?.toString(),
      from: m['from']?.toString(),
      address: address ?? _addr,
    );
  }

  // Buka tab OTP → langsung tampilkan OTP terbaru (sekali per alamat).
  // Buka tab OTP → segarkan OTP terbaru (email baru bisa masuk kapan saja).
  void _onTab() {
    if (currentTab.value == kTabOtp && _ref != null && !_loadingLatest) {
      _loadLatest();
    }
  }

  @override
  void dispose() {
    appState.removeListener(_onState);
    currentTab.removeListener(_onTab);
    Notifier.instance.removeListener(_onNotif);
    otpCommand.removeListener(_onCommand);
    Notifier.instance.clearWaiting();
    _sub?.cancel();
    _waitTick?.cancel();
    _timeoutCtl.dispose();
    _refsCtl.dispose();
    _extractCtl.dispose();
    super.dispose();
  }

  /// Alamat aktif berganti → buang hasil milik alamat lama.
  void _onState() {
    if (!mounted) return;
    if (appState.activeRef != _shownRef) {
      _sub?.cancel();
      _sub = null;
      _stopWaitTick();
      _waitGen++;
      _refGen++;
      _verifyGen++;
      Notifier.instance.setWaiting('wait', null);
      Notifier.instance.setWaiting('stream', null);
      Notifier.instance.setWaiting('link', null);
      setState(() {
        _waitError = null;
        _verifyLoading = false;
        _shownRef = appState.activeRef;
        _loadingLatest = false;
        _latest = null;
        _latestEmpty = null;
        _waitResult = null;
        _waiting = false;
        _streaming = false;
        _streamLog.clear();
        _history = null;
        _verifyLatest = null;
        _verifyWait = null;
        _verifyWaiting = false;
      });
    } else {
      setState(() {});
    }
    _onCommand();
  }

  String? get _ref => appState.activeRef;

  int get _timeout =>
      (int.tryParse(_timeoutCtl.text.trim()) ?? 50).clamp(5, 280);

  void _stopWaitTick() {
    _waitTick?.cancel();
    _waitTick = null;
    _waitPoll?.cancel();
    _waitPoll = null;
  }

  /// Cadangan bila server tidak mengenali kode (mis. "08737 adalah kode
  /// konfirmasi Facebook"): cari OTP di email terbaru inbox.
  /// [maxAgeSec] = hanya email yang masuk dalam N detik terakhir.
  Future<Map<String, dynamic>?> _detectFromInbox(
    String ref, {
    int? maxAgeSec,
  }) async {
    final r = await api.messages(ref, limit: 10, fresh: true);
    final list = listOf(r, ['messages', 'items']).whereType<Map>().toList();
    int ageOf(Map m) {
      final a = m['age_seconds'];
      return a is num ? a.round() : 1 << 30;
    }

    list.sort((a, b) => ageOf(a).compareTo(ageOf(b)));
    for (final m in list) {
      if (maxAgeSec != null && ageOf(m) > maxAgeSec) continue;
      final hit = messageOtp(m);
      if (hit == null) continue;
      return {
        'otp': hit.$1,
        'detected': !hit.$2,
        'message': {
          'subject': m['subject'],
          'from': m['from'],
          'age_seconds': m['age_seconds'],
        },
      };
    }
    return null;
  }

  Future<void> _autoCopy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    HapticFeedback.mediumImpact();
    if (mounted) showOk(context, 'OTP $code disalin otomatis');
  }

  /// Link verifikasi/login masuk: salin otomatis, kirim ke widget, dan
  /// (bila [notify] & tab OTP tidak sedang dilihat) tampilkan notifikasi.
  Future<void> _gotLink(
    String url,
    dynamic msg, {
    String? address,
    bool notify = true,
  }) async {
    final m = msg is Map ? msg : const {};
    await Clipboard.setData(ClipboardData(text: url));
    HapticFeedback.mediumImpact();
    if (mounted) showOk(context, 'Link disalin otomatis');
    if (address == null || address == _addr) {
      HomeWidgets.publishLink(
        url,
        subject: m['subject']?.toString(),
        from: m['from']?.toString(),
      );
    }
    if (!notify ||
        (Notifier.instance.inForeground && currentTab.value == kTabOtp)) {
      return;
    }
    Notifier.instance.linkArrived(
      url,
      subject: m['subject']?.toString(),
      from: m['from']?.toString(),
      address: address ?? _addr,
    );
  }

  Future<void> _loadLatest() async {
    final ref = _ref;
    if (ref == null) return;
    final gen = _refGen;
    setState(() => _loadingLatest = true);
    try {
      final r = await api.otpLatest(ref);
      if (mounted && gen == _refGen) {
        setState(() {
          _latest = r;
          _latestEmpty = null;
        });
        final code = r is Map ? r['otp']?.toString() : null;
        final msg = r is Map && r['message'] is Map
            ? r['message'] as Map
            : null;
        if (code != null && code.isNotEmpty) {
          HomeWidgets.publishOtp(
            code,
            subject: msg?['subject']?.toString(),
            from: msg?['from']?.toString(),
          );
        }
      }
    } on ApiException catch (e) {
      if (!mounted || gen != _refGen) return;
      if (e.code == 'NO_OTP' || e.status == 404) {
        // Server tidak menemukan OTP → coba deteksi sendiri dari inbox.
        Map<String, dynamic>? fb;
        try {
          fb = await _detectFromInbox(ref);
        } catch (_) {}
        if (!mounted || gen != _refGen) return;
        setState(() {
          _latest = fb;
          _latestEmpty = fb != null ? null : 'Belum ada email berisi OTP. Kirim ke alamat ini lalu tekan "Tunggu OTP".';
        });
        if (fb != null) {
          final msg = fb['message'] as Map;
          HomeWidgets.publishOtp(
            '${fb['otp']}',
            subject: msg['subject']?.toString(),
            from: msg['from']?.toString(),
          );
        }
      } else {
        showError(context, e);
      }
    } catch (e) {
      if (mounted && gen == _refGen) showError(context, e);
    } finally {
      if (mounted && gen == _refGen) setState(() => _loadingLatest = false);
    }
  }

  Future<void> _loadHistory() async {
    final ref = _ref;
    if (ref == null) return;
    try {
      final r = await api.otpHistory(ref);
      if (mounted && ref == _ref) setState(() => _history = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _clearHistory() async {
    final ref = _ref;
    if (ref == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Bersihkan riwayat OTP?',
      body: 'Riwayat OTP alamat ini dihapus.',
    );
    if (!ok) return;
    try {
      await api.clearOtpHistory(ref);
      if (mounted) {
        setState(() => _history = null);
        showOk(context, 'Riwayat OTP dibersihkan');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _wait() async {
    if (_waiting) {
      // Batal: request HTTP tetap jalan di belakang, hasilnya diabaikan.
      _waitGen++;
      _stopWaitTick();
      Notifier.instance.setWaiting('wait', null);
      setState(() => _waiting = false);
      showOk(context, 'Menunggu dibatalkan');
      return;
    }
    final ref = _ref;
    if (ref == null) return;
    final gen = ++_waitGen;
    final addr = _addr;
    // Status di notifikasi + foreground service: tetap menunggu walau
    // aplikasi ditinggal ke situs pendaftaran.
    Notifier.instance.ensurePermission();
    Notifier.instance.setWaiting('wait', '$addr · maks $_timeout dtk');
    setState(() {
      _waiting = true;
      _waitResult = null;
      _waitError = null;
      _waitStale = false;
      _waitSecs = 0;
    });
    _waitTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _waitSecs++);
    });
    // Sambil menunggu server, periksa inbox: email BARU yang kodenya tidak
    // dikenali server tetap tertangkap (deteksi aplikasi).
    final started = DateTime.now();
    _waitPoll = Timer.periodic(const Duration(seconds: 6), (_) async {
      if (_polling || gen != _waitGen) return;
      _polling = true;
      try {
        final elapsed = DateTime.now().difference(started).inSeconds;
        final fb = await _detectFromInbox(ref, maxAgeSec: elapsed + 5);
        if (fb == null || gen != _waitGen || !mounted) return;
        _waitGen++; // hasil long-poll server diabaikan
        _stopWaitTick();
        Notifier.instance.setWaiting('wait', null);
        setState(() {
          _waiting = false;
          _waitResult = fb;
          _waitError = null;
          _waitStale = false;
        });
        final code = '${fb['otp']}';
        _autoCopy(code);
        _notifyOtp(code, fb['message'], address: addr);
      } catch (_) {
        // Gagal cek inbox tidak mengganggu penantian utama.
      } finally {
        _polling = false;
      }
    });
    try {
      final r = await api.otpWait(ref, timeout: _timeout);
      if (!mounted || gen != _waitGen) return;
      setState(() => _waitResult = r);
      final code = r is Map ? r['otp']?.toString() : null;
      if (code != null && code.isNotEmpty) {
        _autoCopy(code);
        _notifyOtp(code, r is Map ? r['message'] : null, address: addr);
      }
    } catch (e) {
      if (!mounted || gen != _waitGen) return;
      final stale = e is ApiException && e.details is Map
          ? (e.details as Map)['stale_otp']
          : null;
      if (!Notifier.instance.inForeground) {
        Notifier.instance.otpInfo(
          'Waktu tunggu OTP habis',
          stale is Map
              ? 'Tidak ada OTP baru untuk $addr. OTP lama: ${stale['otp']}'
              : 'Belum ada OTP baru untuk $addr. Buka aplikasi untuk menunggu lagi.',
        );
      }
      setState(() {
        if (stale is Map) {
          _waitResult = {'otp': stale['otp'], 'message': stale};
          _waitStale = true;
        } else {
          _waitError = e is ApiException && e.code == 'WAIT_TIMEOUT'
              ? 'Waktu habis, tidak ada OTP baru dalam $_timeout dtk.'
              : errorText(e);
        }
      });
    } finally {
      if (gen == _waitGen) {
        _stopWaitTick();
        Notifier.instance.setWaiting('wait', null);
        if (mounted) setState(() => _waiting = false);
      }
    }
  }

  Future<void> _waitAny() async {
    final refs = _refsCtl.text
        .split(RegExp(r'[\n,;\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (refs.isEmpty) {
      showError(context, 'Isi dulu daftar alamatnya');
      return;
    }
    if (refs.length > 10) {
      showError(context, 'Maksimal 10 alamat (sekarang ${refs.length})');
      return;
    }
    if (_waitingAny) {
      _cancelWaitAny();
      showOk(context, 'Menunggu dibatalkan');
      return;
    }
    final gen = ++_anyGen;
    setState(() {
      _waitingAny = true;
      _waitAnyResult = null;
      _waitAnyError = null;
    });
    Notifier.instance.ensurePermission();
    Notifier.instance.setWaiting(
      'any',
      '${refs.length} alamat (${_waitAnyMode == 'link' ? 'link' : 'OTP'})',
    );
    try {
      final r = await api.otpWaitAny(
        refs: refs,
        timeout: _timeout,
        mode: _waitAnyMode,
      );
      if (gen != _anyGen) return;
      if (mounted) setState(() => _waitAnyResult = r);
      final addr = r is Map ? (r['address'] ?? r['ref'])?.toString() : null;
      final code = r is Map ? r['otp']?.toString() : null;
      final link = _waitAnyMode == 'link' ? _value(r, 'link') : null;
      if (link != null && link.isNotEmpty) {
        _gotLink(link, r is Map ? r['message'] : null, address: addr);
      } else if (code != null && code.isNotEmpty) {
        _autoCopy(code);
        _notifyOtp(code, r['message'], address: addr);
      }
    } catch (e) {
      if (gen != _anyGen) return;
      if (mounted) {
        setState(
          () => _waitAnyError = e is ApiException && e.code == 'WAIT_TIMEOUT'
              ? 'Waktu habis, belum ada yang datang dalam $_timeout dtk.'
              : errorText(e),
        );
      }
    } finally {
      if (gen == _anyGen) {
        Notifier.instance.setWaiting('any', null);
        if (mounted) setState(() => _waitingAny = false);
      }
    }
  }

  void _toggleStream() {
    if (_streaming) {
      _sub?.cancel();
      _sub = null;
      Notifier.instance.setWaiting('stream', null);
      setState(() => _streaming = false);
      return;
    }
    final ref = _ref;
    if (ref == null) return;
    final addr = _addr;
    setState(() {
      _streaming = true;
      _streamLog.clear();
    });
    Notifier.instance.ensurePermission();
    Notifier.instance.setWaiting('stream', 'Stream real-time · $addr');
    _sub = api
        .otpStream(ref)
        .listen(
          (ev) {
            if (!mounted) return;
            final code = ev['otp'] ?? ev['code'];
            setState(() {
              final detail =
                  code ??
                  ev['subject'] ??
                  ev['message'] ??
                  ev['data'] ??
                  ev['raw'] ??
                  '';
              final t = TimeOfDay.now().format(context);
              _streamLog.insert(0, '$t  ${ev['event']}: $detail');
              if (_streamLog.length > 50) _streamLog.removeLast();
            });
            if (ev['event'] == 'otp' && code != null) {
              _autoCopy(code.toString());
              _notifyOtp(code.toString(), ev, address: addr);
            }
            if (ev['event'] == 'timeout') {
              _sub?.cancel();
              _sub = null;
              Notifier.instance.setWaiting('stream', null);
              setState(() => _streaming = false);
            }
          },
          onError: (e) {
            Notifier.instance.setWaiting('stream', null);
            if (mounted) {
              setState(() {
                _streamLog.insert(0, 'error: ${errorText(e)}');
                _streaming = false;
              });
            }
          },
          onDone: () {
            Notifier.instance.setWaiting('stream', null);
            if (mounted) setState(() => _streaming = false);
          },
        );
  }

  Future<void> _extract() async {
    if (_extractCtl.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    try {
      final r = await api.otpExtract(_extractCtl.text);
      if (mounted) setState(() => _extractResult = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _verify(bool wait) async {
    if (wait && _verifyWaiting) {
      _cancelVerifyWait();
      showOk(context, 'Menunggu link dibatalkan');
      return;
    }
    final ref = _ref;
    if (ref == null) return;
    final gen = _refGen;
    final vgen = wait ? ++_verifyGen : _verifyGen;
    if (wait) {
      setState(() => _verifyWaiting = true);
      Notifier.instance.ensurePermission();
      Notifier.instance.setWaiting('link', 'Link verifikasi · $_addr');
    } else {
      setState(() => _verifyLoading = true);
    }
    try {
      final r = wait
          ? await api.verifyWait(ref, timeout: _timeout)
          : await api.verifyLatest(ref);
      if (wait && vgen != _verifyGen) return;
      if (mounted && gen == _refGen) {
        setState(() {
          if (wait) {
            _verifyWait = r;
          } else {
            _verifyLatest = r;
          }
        });
        final link = _value(r, 'link');
        if (link != null && link.isNotEmpty) {
          // "Tunggu link" → notifikasi bila ditinggal; "Link terbaru" dipicu
          // dari aplikasi → cukup disalin.
          _gotLink(link, r is Map ? r['message'] : null, notify: wait);
        }
      }
    } catch (e) {
      if (wait && vgen != _verifyGen) return;
      if (mounted && gen == _refGen) showError(context, e);
    } finally {
      if (wait && vgen == _verifyGen) {
        Notifier.instance.setWaiting('link', null);
        if (mounted) setState(() => _verifyWaiting = false);
      } else if (!wait && mounted && gen == _refGen) {
        setState(() => _verifyLoading = false);
      }
    }
  }

  /// Kartu pesan biasa (waktu habis / gagal) — pengganti JSON mentah.
  Widget _infoCard(String text, {bool error = false}) {
    final s = Theme.of(context).colorScheme;
    return Card(
      color: error ? s.errorContainer : null,
      child: ListTile(
        leading: Icon(
          error ? Icons.error_outline : Icons.timer_off_outlined,
          color: error ? s.onErrorContainer : s.onSurfaceVariant,
        ),
        title: Text(
          text,
          style: TextStyle(color: error ? s.onErrorContainer : null),
        ),
      ),
    );
  }

  /// Riwayat OTP sebagai daftar (kode · subjek · waktu), JSON hanya cadangan.
  Widget _historyView(dynamic h) {
    final s = Theme.of(context).colorScheme;
    final items = listOf(h, ['items', 'history', 'otps', 'entries']);
    if (items.isEmpty) {
      final empty = h == null || (h is Map && h.isEmpty) || (h is List);
      return empty
          ? Text(
              'Belum ada riwayat OTP.',
              style: TextStyle(color: s.onSurfaceVariant),
            )
          : JsonView(h);
    }
    return Column(
      children: [
        for (final it in items.take(30))
          if (it is Map)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.pin_outlined, size: 20),
              title: Text(
                '${it['otp'] ?? it['code'] ?? '-'}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              subtitle: Text(
                [
                  it['subject'],
                  it['from'],
                  if ((it['at'] ??
                          it['time'] ??
                          it['received_at'] ??
                          it['ts']) !=
                      null)
                    fmtTime(
                      it['at'] ?? it['time'] ?? it['received_at'] ?? it['ts'],
                    ),
                ].where((e) => e != null && '$e'.isNotEmpty).join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.copy, size: 18),
              onTap: () {
                final c = '${it['otp'] ?? it['code'] ?? ''}';
                if (c.isNotEmpty) copyText(context, c, 'OTP $c disalin');
              },
            )
          else
            ListTile(dense: true, title: Text('$it')),
      ],
    );
  }

  /// Ambil nilai utama (kode OTP / URL link) dari respons.
  String? _value(dynamic r, String key) {
    if (r is! Map) return null;
    final v = r[key] ?? (key == 'link' ? r['url'] : null);
    if (v is Map) return (v['url'] ?? v['href'] ?? v['code'])?.toString();
    return v?.toString();
  }

  Widget _otpCard(
    String title,
    dynamic r, {
    String key = 'otp',
    bool stale = false,
  }) {
    final s = Theme.of(context).colorScheme;
    final code = _value(r, key);
    final msg = r is Map && r['message'] is Map ? r['message'] as Map : null;
    final isLink = key == 'link';
    return Card(
      color: code != null && !stale && !isLink ? s.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (stale)
                  Chip(
                    label: const Text('OTP LAMA'),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide.none,
                    backgroundColor: s.tertiaryContainer,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (r == null)
              Text('Belum dimuat.', style: TextStyle(color: s.onSurfaceVariant))
            else if (code != null && code.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      code,
                      maxLines: isLink ? 3 : 1,
                      style: isLink
                          ? const TextStyle(fontSize: 13)
                          : const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 3,
                            ),
                    ),
                  ),
                  if (isLink)
                    IconButton(
                      tooltip: 'Buka di browser',
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () async {
                        final ok = await openExternalUrl(code);
                        if (!ok && mounted) {
                          showError(context, 'Link tidak bisa dibuka: $code');
                        }
                      },
                    ),
                  IconButton.filledTonal(
                    tooltip: 'Salin',
                    icon: const Icon(Icons.copy),
                    onPressed: () => copyText(context, code),
                  ),
                ],
              )
            else
              JsonView(r),
            if (msg != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  [msg['subject'], msg['from'], agoText(msg['age_seconds'])]
                      .where((e) => e != null && e.toString().isNotEmpty)
                      .join(' • '),
                  style: TextStyle(color: s.onSurfaceVariant),
                ),
              ),
            if (r is Map && r['detected'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Dideteksi aplikasi dari subjek/isi email (server tidak '
                  'mengenalinya).',
                  style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children, {Widget? trailing}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ref = _ref;
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('OTP & Verifikasi')),
      body: ref == null
          ? const EmptyState(
              icon: Icons.pin_outlined,
              title: 'Belum ada mailbox aktif',
              subtitle: 'Buat alamat dulu di tab Beranda.',
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => copyText(
                    context,
                    appState.activeAddress ?? ref,
                    'Alamat disalin',
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(Icons.alternate_email, size: 18, color: s.primary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            appState.activeAddress ?? ref,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Icon(Icons.copy, size: 16, color: s.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _loadingLatest ? null : _loadLatest,
                        icon: _loadingLatest
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        label: const Text('OTP terbaru'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _wait,
                        icon: Icon(
                          _waiting ? Icons.close : Icons.hourglass_top,
                        ),
                        label: Text(
                          _waiting ? 'Batal ($_waitSecs dtk)' : 'Tunggu OTP',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Batas waktu tunggu',
                        style: TextStyle(color: s.onSurfaceVariant),
                      ),
                    ),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: _timeoutCtl,
                        enabled: !_waiting,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          suffixText: 'dtk',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                if (int.tryParse(_timeoutCtl.text.trim()) case final t?
                    when t != _timeout)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Batas 5–280 dtk — dipakai $_timeout dtk.',
                      style: TextStyle(color: s.error, fontSize: 12),
                    ),
                  ),
                if (_waiting) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: (_waitSecs / _timeout).clamp(0.0, 1.0),
                  ),
                ],
                const SizedBox(height: 12),
                if (_latestEmpty != null)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.mark_email_unread_outlined),
                      title: Text(_latestEmpty!),
                    ),
                  )
                else
                  _otpCard('OTP terbaru', _latest),
                if (_waitResult != null) ...[
                  const SizedBox(height: 10),
                  _otpCard('Hasil tunggu OTP', _waitResult, stale: _waitStale),
                ],
                if (_waitError != null) ...[
                  const SizedBox(height: 10),
                  _infoCard(
                    _waitError!,
                    error: !_waitError!.startsWith('Waktu habis'),
                  ),
                ],
                const SizedBox(height: 16),
                _section('Stream real-time (SSE)', [
                  Text(
                    'Pantau email masuk secara langsung; OTP otomatis disalin.',
                    style: TextStyle(color: s.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _toggleStream,
                    icon: Icon(_streaming ? Icons.stop : Icons.play_arrow),
                    label: Text(_streaming ? 'Berhenti' : 'Mulai stream'),
                  ),
                  if (_streaming) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                  if (_streamLog.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    for (final l in _streamLog.take(12))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          l,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ]),
                const SizedBox(height: 16),
                _section('Tunggu di banyak alamat', [
                  TextField(
                    controller: _refsCtl,
                    maxLines: 3,
                    minLines: 2,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Daftar ref',
                      helperText: 'Pisahkan dengan baris/koma, maks 10',
                      suffixIcon: IconButton(
                        tooltip: 'Tambah alamat aktif',
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () {
                          final t = _refsCtl.text.trim();
                          _refsCtl.text = t.isEmpty ? ref : '$t\n$ref';
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'otp', label: Text('OTP')),
                          ButtonSegment(value: 'link', label: Text('Link')),
                        ],
                        selected: {_waitAnyMode},
                        onSelectionChanged: (v) =>
                            setState(() => _waitAnyMode = v.first),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: _waitAny,
                          child: Text(_waitingAny ? 'Batal' : 'Tunggu'),
                        ),
                      ),
                    ],
                  ),
                  if (_waitAnyResult != null) ...[
                    const SizedBox(height: 10),
                    if (_value(_waitAnyResult, _waitAnyMode) != null)
                      _otpCard(
                        'Yang pertama datang',
                        _waitAnyResult,
                        key: _waitAnyMode,
                      )
                    else
                      JsonView(_waitAnyResult),
                  ],
                  if (_waitingAny) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                  if (_waitAnyError != null) ...[
                    const SizedBox(height: 10),
                    _infoCard(
                      _waitAnyError!,
                      error: !_waitAnyError!.startsWith('Waktu habis'),
                    ),
                  ],
                ]),
                const SizedBox(height: 16),
                _section('Link verifikasi / reset', [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _verifyLoading
                              ? null
                              : () => _verify(false),
                          child: _verifyLoading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Link terbaru'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _verify(true),
                          child: Text(_verifyWaiting ? 'Batal' : 'Tunggu link'),
                        ),
                      ),
                    ],
                  ),
                  if (_verifyLatest != null) ...[
                    const SizedBox(height: 10),
                    _otpCard('Link terbaru', _verifyLatest, key: 'link'),
                  ],
                  if (_verifyWait != null) ...[
                    const SizedBox(height: 10),
                    _otpCard('Hasil tunggu link', _verifyWait, key: 'link'),
                  ],
                ]),
                const SizedBox(height: 16),
                _section(
                  'Riwayat OTP',
                  [if (_history != null) _historyView(_history)],
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _loadHistory,
                        child: const Text('Muat'),
                      ),
                      TextButton(
                        onPressed: _clearHistory,
                        child: const Text('Bersihkan'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _section('Uji ekstrak OTP dari teks', [
                  TextField(
                    controller: _extractCtl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Tempel isi email di sini',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: _extract,
                    child: const Text('Ekstrak'),
                  ),
                  if (_extractResult != null) ...[
                    const SizedBox(height: 10),
                    JsonView(_extractResult),
                  ],
                ]),
              ],
            ),
    );
  }
}
