// Layar Favorit + Menu dan sub-layar: Varian, Gmail, Alias, Domain,
// Riwayat, Pantauan & Notifikasi, Debug, Admin, Tentang.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'api.dart';
import 'main.dart';
import 'update.dart';
import 'screens_main.dart' show fmtTime, parseApiTime;

/// "baru saja" / "5 mnt lalu" dari waktu ISO.
String _when(dynamic iso) {
  final d = parseApiTime(iso);
  if (d == null) return '';
  final s = DateTime.now().toUtc().difference(d.toUtc()).inSeconds;
  return agoText(s < 0 ? 0 : s);
}

String _pretty(dynamic v) {
  try {
    return const JsonEncoder.withIndent('  ').convert(v);
  } catch (_) {
    return v.toString();
  }
}

Widget _heading(String t) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)),
);

// ============================ FAVORIT ============================
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});
  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<dynamic> _items = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    currentTab.addListener(_onTab);
    appState.addListener(_onActive);
    _load();
  }

  // Sorotan "aktif" harus pindah begitu alamat aktif berganti.
  void _onActive() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    currentTab.removeListener(_onTab);
    appState.removeListener(_onActive);
    super.dispose();
  }

  // Favorit bisa ditambah dari tab lain → segarkan saat tab ini dibuka.
  void _onTab() {
    if (currentTab.value == kTabFavorites) _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.favorites();
      final list = listOf(r, ['items', 'favorites']).toList();
      setFavoritesFrom(list);
      // Yang disematkan selalu di atas.
      list.sort((a, b) {
        final pa = a is Map && a['pinned'] == true ? 0 : 1;
        final pb = b is Map && b['pinned'] == true ? 0 : 1;
        return pa.compareTo(pb);
      });
      if (mounted) {
        setState(() {
          _items = list;
          _loading = false;
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = errorText(e);
        });
        // Daftar lama tetap tampil; beri tahu bahwa penyegaran gagal.
        if (_items.isNotEmpty) showError(context, e);
      }
    }
  }

  String _addr(dynamic f) =>
      f is Map ? (f['address'] ?? f['ref'] ?? '').toString() : f.toString();

  String _refOf(dynamic f) =>
      f is Map ? (f['ref'] ?? f['address'] ?? '').toString() : f.toString();

  Future<void> _use(dynamic f) async {
    final addr = _addr(f);
    if (addr.isEmpty) return;
    await appState.setActive(_refOf(f), addr);
    if (mounted) showOk(context, 'Aktif: $addr');
  }

  Future<void> _export() async {
    try {
      final r = await api.exportFavorites();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ekspor favorit'),
          content: SingleChildScrollView(child: JsonView(r)),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                copyText(context, _pretty(r), 'JSON ekspor disalin');
              },
              child: const Text('Salin JSON'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Tutup'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _import() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Impor favorit'),
        content: TextField(
          controller: ctl,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'Tempel JSON {"items":[...]} atau array',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Impor'),
          ),
        ],
      ),
    );
    // Controller dialog sengaja tidak di-dispose di sini: showDialog selesai
    // saat animasi tutup baru mulai dan TextField masih terpasang.
    final text = ctl.text;
    if (ok != true || text.trim().isEmpty) return;
    try {
      final parsed = jsonDecode(text);
      final items = listOf(parsed);
      if (items.isEmpty) throw const FormatException('daftar items kosong');
      final r = await api.importFavorites(items);
      if (mounted) {
        showOk(
          context,
          r is Map
              ? 'Impor selesai: ${r['added'] ?? 0} baru, ${r['updated'] ?? 0} diperbarui, ${r['skipped'] ?? 0} dilewati'
              : 'Impor selesai',
        );
        _load();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _clearAll() async {
    final ok = await confirmDialog(
      context,
      title: 'Bersihkan semua favorit?',
      body: 'Seluruh favorit permanen akan dihapus.',
    );
    if (!ok) return;
    try {
      await api.clearFavorites();
      if (mounted) showOk(context, 'Semua favorit dihapus');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _edit(dynamic f) async {
    final addr = _addr(f);
    final label = TextEditingController(
      text: f is Map ? (f['label'] ?? '').toString() : '',
    );
    final note = TextEditingController(
      text: f is Map ? (f['note'] ?? '').toString() : '',
    );
    final save = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Ubah favorit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(addr, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            TextField(
              controller: label,
              decoration: const InputDecoration(
                labelText: 'Label (kosong = tanpa label)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: note,
              decoration: const InputDecoration(
                labelText: 'Catatan (opsional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    final l = label.text.trim(), n = note.text.trim();
    if (save != true) return;
    try {
      await api.patchFavorite(addr, label: l, note: n);
      if (mounted) showOk(context, 'Label & catatan disimpan');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _menu(String v, dynamic f) async {
    final addr = _addr(f);
    final pinned = f is Map && f['pinned'] == true;
    try {
      if (v == 'use') {
        await _use(f);
      } else if (v == 'copy') {
        await copyText(context, addr, 'Alamat disalin');
      } else if (v == 'pin') {
        await api.patchFavorite(addr, pinned: !pinned);
        if (mounted) {
          showOk(context, pinned ? 'Sematan dilepas' : 'Disematkan di atas');
        }
        _load();
      } else if (v == 'edit') {
        await _edit(f);
      } else if (v == 'del') {
        final ok = await confirmDialog(
          context,
          title: 'Hapus dari favorit?',
          body: addr,
        );
        if (!ok) return;
        await api.removeFavorite(addr);
        if (mounted) showOk(context, 'Dihapus dari favorit');
        _load();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorit'),
        actions: [
          IconButton(
            tooltip: 'Ekspor',
            onPressed: _export,
            icon: const Icon(Icons.upload_outlined),
          ),
          IconButton(
            tooltip: 'Impor',
            onPressed: _import,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'Bersihkan semua',
            onPressed: _items.isEmpty ? null : _clearAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 80),
                        EmptyState(
                          icon: _err != null
                              ? Icons.error_outline
                              : Icons.star_outline,
                          title: _err != null
                              ? 'Gagal memuat favorit'
                              : 'Belum ada favorit',
                          subtitle: _err ?? 'Simpan alamat penting dari tab Beranda (tombol Favorit).',
                        ),
                      ],
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final f = _items[i];
                        final addr = _addr(f);
                        final label = f is Map ? f['label']?.toString() : null;
                        final note = f is Map ? f['note']?.toString() : null;
                        final otp = f is Map ? f['otp_count'] : null;
                        final pinned = f is Map && f['pinned'] == true;
                        final active = addr == appState.activeAddress;
                        final sub = [
                          if (label?.isNotEmpty == true) addr,
                          if (note?.isNotEmpty == true) note,
                          if (otp is num && otp > 0) 'OTP $otp×',
                        ].join(' • ');
                        return ListTile(
                          selected: active,
                          leading: Icon(
                            pinned ? Icons.push_pin : Icons.star,
                            color: pinned ? s.primary : null,
                          ),
                          title: Text(
                            label?.isNotEmpty == true ? label! : addr,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: sub.isEmpty ? null : Text(sub),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) => _menu(v, f),
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'use',
                                child: Text('Jadikan aktif'),
                              ),
                              const PopupMenuItem(
                                value: 'copy',
                                child: Text('Salin alamat'),
                              ),
                              PopupMenuItem(
                                value: 'pin',
                                child: Text(pinned ? 'Lepas pin' : 'Sematkan'),
                              ),
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('Ubah label & catatan'),
                              ),
                              const PopupMenuItem(
                                value: 'del',
                                child: Text('Hapus favorit'),
                              ),
                            ],
                          ),
                          onTap: () => _use(f),
                        );
                      },
                    ),
            ),
    );
  }
}

// ============================ MENU ============================
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, String, Widget)>[
      (
        Icons.call_split,
        'Varian alamat',
        'Titik & plus dari alamat aktif',
        const VariantsScreen(),
      ),
      (
        Icons.mail_outline,
        'Varian Gmail saya',
        'Dari alamat @gmail.com mana pun',
        const GmailVariantsScreen(),
      ),
      (
        Icons.list_alt,
        'Alias (alias.md)',
        'Lihat, edit, validasi daftar alias',
        const AliasScreen(),
      ),
      (
        Icons.language,
        'Domain',
        'Cari, acak, grup, dan uji domain',
        const DomainsScreen(),
      ),
      (
        Icons.history,
        'Riwayat',
        'Alamat baru dipakai + feed aktivitas',
        const HistoryScreen(),
      ),
      (
        Icons.visibility_outlined,
        'Pantauan & notifikasi',
        'Watch OTP/link + tes notifikasi',
        const WatchScreen(),
      ),
      (
        Icons.bug_report_outlined,
        'Debug',
        'Diagnosis upstream per alamat',
        const DebugScreen(),
      ),
      (
        Icons.admin_panel_settings_outlined,
        'Admin',
        'Log, config, domain & pola OTP kustom',
        const AdminScreen(),
      ),
      (
        Icons.system_update_outlined,
        'Pembaruan aplikasi',
        'Cek versi terbaru, unduh & pasang APK',
        const UpdateScreen(),
      ),
      (
        Icons.info_outline,
        'Tentang & status',
        'Info server /me + health',
        const AboutScreen(),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Menu')),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final (icon, title, sub, page) = items[i];
          return ListTile(
            leading: Icon(icon),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => page),
            ),
          );
        },
      ),
    );
  }
}

// ============================ VARIAN ============================
class VariantsScreen extends StatefulWidget {
  const VariantsScreen({super.key});
  @override
  State<VariantsScreen> createState() => _VariantsScreenState();
}

class _VariantsScreenState extends State<VariantsScreen> {
  String _mode = 'dot';
  final _tag = TextEditingController();
  dynamic _result;
  bool _busy = false;
  int _seq = 0; // respons permintaan lama (mode lama) diabaikan

  @override
  void initState() {
    super.initState();
    if (appState.activeRef != null) _load();
  }

  @override
  void dispose() {
    _tag.dispose();
    super.dispose();
  }

  String _randomTag() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(4, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<void> _load() async {
    final ref = appState.activeRef;
    if (ref == null) {
      showError(context, 'Belum ada mailbox aktif');
      return;
    }
    if (_mode != 'dot' && _tag.text.trim().isEmpty) _tag.text = _randomTag();
    final seq = ++_seq;
    setState(() => _busy = true);
    try {
      final r = await api.variants(
        ref,
        mode: _mode,
        count: 30,
        tag: _tag.text.trim(),
      );
      if (mounted && seq == _seq) setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted && seq == _seq) setState(() => _busy = false);
    }
  }

  /// Varian titik: inbox-nya sama dengan alamat varian → langsung pakai.
  Future<void> _useDot(String address) async {
    await appState.setActive(address, address);
    if (mounted) await copyText(context, address, 'Aktif & disalin: $address');
  }

  /// Varian plus: server membuat mailbox varian; inbox yang dibaca =
  /// alamat dasar, alamat yang dibagikan = display_address.
  Future<void> _usePlus(String? tag) async {
    final ref = appState.activeRef;
    if (ref == null) return;
    final t = (tag ?? _tag.text).trim();
    try {
      final r = await api.variantCreate(
        ref,
        mode: 'plus',
        tag: t.isEmpty ? _randomTag() : t,
      );
      final inbox = (r['address'] ?? '').toString();
      final shown = (r['display_address'] ?? inbox).toString();
      if (inbox.isNotEmpty) {
        await appState.setActive((r['ref'] ?? inbox).toString(), shown);
      }
      if (mounted) await copyText(context, shown, 'Aktif & disalin: $shown');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _row(String shown, String note, VoidCallback onUse) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.alternate_email, size: 20),
    title: Text(shown),
    subtitle: note.isEmpty ? null : Text(note),
    onTap: () => copyText(context, shown),
    trailing: TextButton(onPressed: onUse, child: const Text('Pakai')),
  );

  List<Widget> _sections() {
    final r = _result;
    if (r == null) return const [];
    final s = Theme.of(context).colorScheme;
    final out = <Widget>[];
    if (r is Map && r['base_address'] != null) {
      out.add(
        Text(
          'Dasar: ${r['base_address']}',
          style: TextStyle(color: s.onSurfaceVariant),
        ),
      );
    }
    final dot = r is Map && r['dot'] is Map ? r['dot'] as Map : null;
    final plus = r is Map && r['plus'] is Map ? r['plus'] as Map : null;
    if (dot != null) {
      final items = listOf(dot);
      final total = dot['total_possible'];
      out.add(const SizedBox(height: 12));
      out.add(
        _heading('Varian titik${total is num ? ' · $total kemungkinan' : ''}'),
      );
      if (dot['note'] != null) {
        out.add(
          Text(
            dot['note'].toString(),
            style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
          ),
        );
      }
      if (items.isEmpty) {
        out.add(Text((dot['reason'] ?? 'Tidak ada varian titik.').toString()));
      }
      for (final v in items) {
        final a = v is Map ? (v['address'] ?? '').toString() : v.toString();
        final n = v is Map && v['dots'] != null ? '${v['dots']} titik' : '';
        out.add(_row(a, n, () => _useDot(a)));
      }
    }
    if (plus != null) {
      final items = listOf(plus);
      out.add(const SizedBox(height: 12));
      out.add(_heading('Varian plus'));
      if (plus['note'] != null) {
        out.add(
          Text(
            plus['note'].toString(),
            style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
          ),
        );
      }
      for (final e in listOf(plus['errors'])) {
        out.add(
          Text(
            e is Map ? '${e['message'] ?? e}' : e.toString(),
            style: TextStyle(color: s.error),
          ),
        );
      }
      for (final v in items) {
        final shown = v is Map
            ? (v['display'] ?? v['address'] ?? '').toString()
            : v.toString();
        final inbox = v is Map ? (v['address'] ?? '').toString() : '';
        final tag = v is Map ? v['tag']?.toString() : null;
        out.add(
          _row(
            shown,
            inbox.isEmpty ? '' : 'inbox: $inbox',
            () => _usePlus(tag),
          ),
        );
      }
    }
    if (dot == null && plus == null) {
      // Bentuk respons lama/lain: daftar alamat polos.
      final items = listOf(r, ['variants', 'items']);
      for (final v in items) {
        final a = v is Map ? (v['address'] ?? '').toString() : v.toString();
        out.add(_row(a, '', () => _useDot(a)));
      }
      if (items.isEmpty) out.add(JsonView(r));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Varian alamat')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Dari: ${appState.activeAddress ?? '-'}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dot', label: Text('Titik')),
              ButtonSegment(value: 'plus', label: Text('Plus')),
              ButtonSegment(value: 'both', label: Text('Keduanya')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) {
              setState(() => _mode = v.first);
              _load();
            },
          ),
          if (_mode != 'dot') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _tag,
              autocorrect: false,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                labelText: 'Tag plus (alamat+tag@…)',
                suffixIcon: IconButton(
                  tooltip: 'Tag acak',
                  icon: const Icon(Icons.casino_outlined),
                  onPressed: () {
                    _tag.text = _randomTag();
                    _load();
                  },
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _load,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.shuffle),
                  label: const Text('Tampilkan / acak'),
                ),
              ),
              if (_mode != 'dot') ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () => _usePlus(null),
                    child: const Text('Pakai tag ini'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          ..._sections(),
        ],
      ),
    );
  }
}

// ============================ GMAIL ============================
class GmailVariantsScreen extends StatefulWidget {
  const GmailVariantsScreen({super.key});
  @override
  State<GmailVariantsScreen> createState() => _GmailVariantsScreenState();
}

class _GmailVariantsScreenState extends State<GmailVariantsScreen> {
  final _email = TextEditingController();
  String _mode = 'dot';
  bool _random = false;
  int _seq = 0; // respons permintaan lama (mode lama) diabaikan
  final List<dynamic> _items = [];
  dynamic _last;
  int _offset = 0;
  bool _busy = false;

  static const _page = 100;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  int? get _total {
    final t = _last is Map ? _last['total'] : null;
    return t is num ? t.toInt() : null;
  }

  Future<void> _load({bool more = false}) async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      showError(context, 'Isi alamat Gmail dulu');
      return;
    }
    FocusScope.of(context).unfocus();
    final seq = ++_seq;
    setState(() => _busy = true);
    try {
      final off = more ? _offset : 0;
      final r = await api.gmailVariants(
        email: email,
        mode: _mode,
        limit: _page,
        order: _mode == 'dot' ? (_shuffled ? 'random' : 'seq') : null,
        offset: _shuffled ? null : off,
      );
      if (!mounted || seq != _seq) return;
      final got = listOf(r, ['items', 'variants']);
      setState(() {
        if (!more) _items.clear();
        _items.addAll(got);
        _offset = off + got.length;
        _last = r;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted && seq == _seq) setState(() => _busy = false);
    }
  }

  /// Urutan acak hanya berlaku di mode titik.
  bool get _shuffled => _mode == 'dot' && _random;

  String _addrOf(dynamic v) =>
      v is Map ? (v['address'] ?? '').toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final r = _last;
    final total = _total;
    final canMore =
        !_shuffled && total != null && _offset < total && _items.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Varian Gmail saya'),
        actions: [
          IconButton(
            tooltip: 'Salin semua yang tampil',
            onPressed: _items.isEmpty
                ? null
                : () => copyText(
                    context,
                    _items.map(_addrOf).join('\n'),
                    '${_items.length} alamat disalin',
                  ),
            icon: const Icon(Icons.copy_all),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            onSubmitted: (_) => _load(),
            decoration: const InputDecoration(
              labelText: 'Alamat @gmail.com',
              prefixIcon: Icon(Icons.mail_outline),
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dot', label: Text('Titik')),
              ButtonSegment(value: 'plus', label: Text('Plus')),
              ButtonSegment(value: 'both', label: Text('Keduanya')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) {
              setState(() => _mode = v.first);
              if (_items.isNotEmpty) _load();
            },
          ),
          if (_mode == 'dot')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Urutan acak'),
              value: _random,
              onChanged: (v) {
                setState(() => _random = v);
                if (_items.isNotEmpty) _load();
              },
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _load,
            child: Text(_busy ? 'Memuat…' : 'Hasilkan varian'),
          ),
          if (r is Map) ...[
            const SizedBox(height: 12),
            Text(
              [
                if (r['base'] != null) 'Nama dasar: ${r['base']}',
                'Menampilkan ${_items.length}${total != null ? ' dari $total' : ''}',
                if (r['alias_count'] != null) '${r['alias_count']} alias',
              ].join(' • '),
              style: TextStyle(color: s.onSurfaceVariant),
            ),
            if (r['hint'] != null)
              Text(
                r['hint'].toString(),
                style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
              ),
          ],
          const SizedBox(height: 6),
          for (final v in _items)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(_addrOf(v)),
              subtitle: v is Map && (v['dots'] != null || v['source'] != null)
                  ? Text(
                      v['dots'] != null
                          ? '${v['dots']} titik'
                          : v['source'].toString(),
                    )
                  : null,
              trailing: const Icon(Icons.copy, size: 18),
              onTap: () => copyText(context, _addrOf(v)),
            ),
          if (canMore)
            OutlinedButton(
              onPressed: _busy ? null : () => _load(more: true),
              child: const Text('Muat lagi'),
            ),
          if (r != null && _items.isEmpty) JsonView(r),
        ],
      ),
    );
  }
}

// ============================ ALIAS ============================
class AliasScreen extends StatefulWidget {
  const AliasScreen({super.key});
  @override
  State<AliasScreen> createState() => _AliasScreenState();
}

class _AliasScreenState extends State<AliasScreen> {
  final _ctl = TextEditingController();
  final _find = TextEditingController();
  List<dynamic> _aliases = [];
  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  // Belum pernah berhasil dimuat → jangan izinkan simpan (bisa menimpa
  // alias.md di server dengan isi kosong).
  bool _loaded = false;
  String? _loadError;
  Map? _summary;
  List<dynamic> _issues = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctl.dispose();
    _find.dispose();
    super.dispose();
  }

  Future<void> _load({bool askIfDirty = false}) async {
    if (askIfDirty && _dirty) {
      final ok = await confirmDialog(
        context,
        title: 'Buang perubahan?',
        body: 'Suntingan alias.md yang belum disimpan akan hilang.',
        confirmLabel: 'Buang',
      );
      if (!ok) return;
    }
    try {
      final r = await api.aliasGet();
      if (mounted) {
        setState(() {
          _aliases = listOf(r, ['aliases']);
          // raw bisa null/hilang saat alias.md sudah dihapus.
          _ctl.text = r is Map && r['raw'] is String ? r['raw'] : '';
          _dirty = false;
          _issues = [];
          _summary = null;
          _loading = false;
          _loaded = true;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = errorText(e);
        });
        showError(context, e);
      }
    }
  }

  void _showIssues(dynamic data) {
    setState(() {
      _issues = data is Map ? listOf(data['issues']) : const [];
      _summary = data is Map && data['summary'] is Map
          ? data['summary'] as Map
          : null;
    });
  }

  Future<void> _validate() async {
    FocusScope.of(context).unfocus();
    try {
      final r = await api.aliasValidate(_ctl.text);
      if (!mounted) return;
      _showIssues(r);
      final valid = r is Map ? r['valid'] != false : true;
      final n = _summary?['aliases'];
      if (valid) {
        showOk(context, 'Valid${n != null ? ' · $n alias' : ''}');
      } else {
        showError(context, 'Ada error di alias.md — lihat daftar di bawah');
      }
    } catch (e) {
      if (mounted) {
        if (e is ApiException) _showIssues(e.details);
        showError(context, e);
      }
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      final r = await api.aliasPutRaw(_ctl.text);
      if (!mounted) return;
      final d = r.data;
      _showIssues(d);
      setState(() {
        _dirty = false;
        if (d is Map) {
          // Server mengembalikan versi rapi (duplikat dibuang).
          if (d['cleaned'] is String) _ctl.text = d['cleaned'];
          if (d['aliases'] is List) _aliases = d['aliases'];
        }
      });
      final n = d is Map ? (d['count'] ?? _summary?['aliases']) : null;
      showOk(context, 'alias.md disimpan${n != null ? ' · $n alias' : ''}');
    } catch (e) {
      if (mounted) {
        if (e is ApiException) _showIssues(e.details);
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _wipe() async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus alias.md?',
      body: 'Seluruh daftar alias akan dihapus.',
    );
    if (!ok) return;
    try {
      await api.aliasDelete();
      if (mounted) showOk(context, 'alias.md dihapus');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _issuesView() {
    final s = Theme.of(context).colorScheme;
    final list = [..._issues]
      ..sort((a, b) {
        int lv(dynamic i) => i is Map && i['level'] == 'error' ? 0 : 1;
        return lv(a).compareTo(lv(b));
      });
    final sum = _summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sum != null)
          Text(
            [
              '${sum['aliases'] ?? 0} alias',
              if ((sum['duplicates_merged'] ?? 0) != 0)
                '${sum['duplicates_merged']} duplikat digabung',
              if ((sum['errors'] ?? 0) != 0) '${sum['errors']} error',
            ].join(' · '),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: (sum['errors'] ?? 0) != 0 ? s.error : null,
            ),
          ),
        for (final i in list.take(30))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              i is Map
                  ? '${(i['line'] ?? 0) is num && (i['line'] ?? 0) > 0 ? 'Baris ${i['line']}: ' : ''}${i['message'] ?? i}'
                  : i.toString(),
              style: TextStyle(
                color: i is Map && i['level'] == 'error'
                    ? s.error
                    : s.onSurfaceVariant,
              ),
            ),
          ),
        if (list.length > 30)
          Text(
            '…dan ${list.length - 30} catatan lainnya.',
            style: TextStyle(color: s.onSurfaceVariant),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final q = _find.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? _aliases
        : _aliases.where((a) {
            final t = a is Map
                ? '${a['name'] ?? ''} ${a['address'] ?? ''}'
                : a.toString();
            return t.toLowerCase().contains(q);
          }).toList();
    // Jangan buang suntingan alias.md yang belum disimpan saat menekan kembali.
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await confirmDialog(
          context,
          title: 'Buang perubahan?',
          body: 'Suntingan alias.md yang belum disimpan akan hilang.',
          confirmLabel: 'Buang',
        );
        if (ok && context.mounted) {
          setState(() => _dirty = false);
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Alias (alias.md)'),
          actions: [
            IconButton(
              tooltip: 'Hapus alias.md',
              onPressed: _wipe,
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: 'Muat ulang',
              onPressed: () => _load(askIfDirty: true),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_aliases.isNotEmpty) ...[
                    _heading('Alias terdaftar (${_aliases.length})'),
                    if (_aliases.length > 8)
                      TextField(
                        controller: _find,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Cari alias',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                    for (final a in shown.take(100))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          a is Map
                              ? (a['name'] ?? '').toString()
                              : a.toString(),
                        ),
                        subtitle: Text(
                          a is Map
                              ? [
                                  (a['address'] ?? a['domain'] ?? '')
                                      .toString(),
                                  if (a['random'] == true) 'acak',
                                ].join(' • ')
                              : '',
                        ),
                        trailing: IconButton(
                          tooltip: 'Jadikan aktif',
                          icon: const Icon(Icons.play_circle_outline),
                          onPressed: () async {
                            final addr = a is Map
                                ? (a['address'] ?? '').toString()
                                : '';
                            if (addr.isEmpty) return;
                            await appState.setActive(
                              (a['name'] ?? addr).toString(),
                              addr,
                            );
                            if (context.mounted) {
                              showOk(context, 'Aktif: $addr');
                            }
                          },
                        ),
                      ),
                    if (shown.length > 100)
                      Text(
                        'Menampilkan 100 dari ${shown.length}; pakai pencarian.',
                        style: TextStyle(color: s.onSurfaceVariant),
                      ),
                    const SizedBox(height: 12),
                  ],
                  if (!_loaded && _loadError != null) ...[
                    Card(
                      color: s.errorContainer,
                      child: ListTile(
                        leading: Icon(
                          Icons.cloud_off,
                          color: s.onErrorContainer,
                        ),
                        title: Text(
                          'alias.md gagal dimuat',
                          style: TextStyle(color: s.onErrorContainer),
                        ),
                        subtitle: Text(
                          '$_loadError\nSimpan dinonaktifkan agar alias di server tidak tertimpa.',
                          style: TextStyle(color: s.onErrorContainer),
                        ),
                        trailing: IconButton(
                          tooltip: 'Coba lagi',
                          icon: Icon(Icons.refresh, color: s.onErrorContainer),
                          onPressed: _load,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _heading('Isi alias.md${_dirty ? ' (belum disimpan)' : ''}'),
                  TextField(
                    controller: _ctl,
                    maxLines: 14,
                    minLines: 6,
                    autocorrect: false,
                    onChanged: (_) {
                      if (!_dirty) setState(() => _dirty = true);
                    },
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      alignLabelWithHint: true,
                      labelText: 'Markdown alias',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _loaded ? _validate : null,
                          child: const Text('Validasi'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: _saving || !_loaded ? null : _save,
                          child: Text(_saving ? 'Menyimpan…' : 'Simpan'),
                        ),
                      ),
                    ],
                  ),
                  if (_summary != null || _issues.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _issuesView(),
                  ],
                ],
              ),
      ),
    );
  }
}

// ============================ DOMAIN ============================
class DomainsScreen extends StatefulWidget {
  const DomainsScreen({super.key});
  @override
  State<DomainsScreen> createState() => _DomainsScreenState();
}

class _DomainsScreenState extends State<DomainsScreen> {
  final _q = TextEditingController();
  final _check = TextEditingController();
  dynamic _result;
  List<dynamic> _groups = [];
  String? _group;
  int _page = 1;
  dynamic _random;
  dynamic _checkResult;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadGroups();
    _search();
  }

  @override
  void dispose() {
    _q.dispose();
    _check.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _loadGroups() => _run(() async {
    final r = await api.domainGroups();
    if (mounted) setState(() => _groups = listOf(r, ['groups', 'items']));
  });

  Future<void> _search({int page = 1}) async {
    setState(() => _busy = true);
    await _run(() async {
      final r = await api.domains(
        q: _q.text.trim().toLowerCase(),
        group: _group,
        page: page,
        perPage: 30,
      );
      if (mounted) {
        setState(() {
          _result = r;
          _page = page;
        });
      }
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final r = _result;
    final items = listOf(r, ['items', 'domains']);
    final pages = r is Map && r['pages'] is num
        ? (r['pages'] as num).toInt()
        : 1;
    final total = r is Map ? r['total'] : null;
    final rand = _random is Map
        ? (_random['domain'] ?? _random['name'])?.toString()
        : _random is String
        ? _random as String
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Domain')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _q,
            autocorrect: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: 'Cari domain',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: 'Cari',
                onPressed: _search,
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
          if (_groups.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Semua'),
                  selected: _group == null,
                  onSelected: (_) {
                    setState(() => _group = null);
                    _search();
                  },
                ),
                for (final g in _groups)
                  if (g is Map && g['name'] != null)
                    ChoiceChip(
                      label: Text('${g['name']} (${g['count'] ?? '-'})'),
                      selected: _group == g['name'].toString(),
                      onSelected: (_) {
                        setState(() => _group = g['name'].toString());
                        _search();
                      },
                    ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _run(() async {
              final r = await api.domainRandom(group: _group);
              if (mounted) setState(() => _random = r);
            }),
            icon: const Icon(Icons.casino_outlined),
            label: Text(
              _group == null ? 'Domain acak' : 'Domain acak ($_group)',
            ),
          ),
          if (_random != null) ...[
            const SizedBox(height: 8),
            if (rand != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.language),
                  title: Text(
                    rand,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  trailing: const Icon(Icons.copy, size: 18),
                  onTap: () => copyText(context, rand),
                ),
              )
            else
              JsonView(_random),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _check,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Uji domain (cth: mail.com)',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () {
                  if (_check.text.trim().isEmpty) return;
                  _run(() async {
                    final r = await api.domainCheck(_check.text.trim());
                    if (mounted) setState(() => _checkResult = r);
                  });
                },
                child: const Text('Uji'),
              ),
            ],
          ),
          if (_checkResult != null) ...[
            const SizedBox(height: 10),
            JsonView(_checkResult),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _heading(
                  'Daftar domain${total != null ? ' · $total' : ''}',
                ),
              ),
              if (_busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (r != null && items.isEmpty && r is! Map) JsonView(r),
          if (r is Map && items.isEmpty)
            Text(
              'Tidak ada hasil',
              style: TextStyle(color: s.onSurfaceVariant),
            ),
          for (final d in items)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                d is Map ? (d['domain'] ?? '').toString() : '$d',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              subtitle: d is Map && d['group'] != null
                  ? Text(d['group'].toString())
                  : null,
              trailing: const Icon(Icons.copy, size: 18),
              onTap: () => copyText(
                context,
                d is Map ? (d['domain'] ?? '').toString() : '$d',
              ),
            ),
          if (pages > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Halaman sebelumnya',
                  onPressed: _page <= 1 || _busy
                      ? null
                      : () => _search(page: _page - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('Hal $_page / $pages'),
                IconButton(
                  tooltip: 'Halaman berikutnya',
                  onPressed: _page >= pages || _busy
                      ? null
                      : () => _search(page: _page + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ============================ RIWAYAT ============================
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  dynamic _recent;
  dynamic _events;
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    appState.addListener(_onActive);
    _load();
  }

  void _onActive() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appState.removeListener(_onActive);
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final r = await api.history(limit: 50);
      if (mounted) setState(() => _recent = r);
    } catch (e) {
      if (mounted) setState(() => _err = errorText(e));
    }
    try {
      final e = await api.historyEvents(limit: 50);
      if (mounted) setState(() => _events = e);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _clearAll() async {
    final ok = await confirmDialog(
      context,
      title: 'Bersihkan semua riwayat?',
      body: 'Riwayat alamat + feed aktivitas dihapus.',
    );
    if (!ok) return;
    try {
      await api.clearHistory(scope: 'all');
      if (mounted) showOk(context, 'Riwayat dihapus');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteOne(String addr) async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus dari riwayat?',
      body: '$addr hilang dari daftar "Baru dipakai" (inbox tidak terhapus).',
    );
    if (!ok) return;
    try {
      await api.deleteRecent(addr);
      if (mounted) showOk(context, 'Dihapus dari riwayat');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _empty(IconData icon, String title) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      children: [
        const SizedBox(height: 80),
        EmptyState(icon: icon, title: title, subtitle: _err),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final recent = listOf(_recent, ['items', 'recent']);
    final events = listOf(_events, ['events', 'items']);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Riwayat'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Bersihkan semua riwayat',
            onPressed: _clearAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Baru dipakai'),
            Tab(text: 'Feed aktivitas'),
          ],
        ),
      ),
      body: _loading && _recent == null && _events == null
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                recent.isEmpty
                    ? _empty(Icons.history, 'Belum ada riwayat')
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: recent.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final it = recent[i] is Map ? recent[i] as Map : {};
                            final addr = (it['address'] ?? '').toString();
                            final ref = (it['ref'] ?? addr).toString();
                            final alias = it['alias']?.toString();
                            final otp = it['otp_count'];
                            final sub = [
                              if (alias != null && alias.isNotEmpty) addr,
                              _when(it['last_used_at']),
                              if (otp is num && otp > 0) 'OTP $otp×',
                            ].where((e) => e.isNotEmpty).join(' • ');
                            return ListTile(
                              selected: addr == appState.activeAddress,
                              title: Text(
                                alias != null && alias.isNotEmpty
                                    ? alias
                                    : addr,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: sub.isEmpty ? null : Text(sub),
                              trailing: IconButton(
                                tooltip: 'Hapus dari riwayat',
                                icon: const Icon(Icons.close),
                                onPressed: () => _deleteOne(addr),
                              ),
                              onTap: () async {
                                await appState.setActive(ref, addr);
                                if (context.mounted) {
                                  showOk(context, 'Aktif: $addr');
                                }
                              },
                            );
                          },
                        ),
                      ),
                events.isEmpty
                    ? _empty(Icons.feed_outlined, 'Belum ada aktivitas')
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: events.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final e = events[i];
                            if (e is! Map) {
                              return ListTile(title: Text(e.toString()));
                            }
                            final type =
                                (e['type'] ??
                                        e['event'] ??
                                        e['kind'] ??
                                        'event')
                                    .toString();
                            final at =
                                e['at'] ??
                                e['ts'] ??
                                e['time'] ??
                                e['created_at'];
                            final ref = e['address'] ?? e['ref'];
                            return ExpansionTile(
                              title: Text(
                                type,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                [
                                  if (ref != null) ref.toString(),
                                  if (at != null) fmtTime(at),
                                ].join(' • '),
                              ),
                              childrenPadding: const EdgeInsets.fromLTRB(
                                16,
                                0,
                                16,
                                12,
                              ),
                              children: [JsonView(e)],
                            );
                          },
                        ),
                      ),
              ],
            ),
    );
  }
}

// ====================== PANTAUAN & NOTIFIKASI ======================
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key});
  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  dynamic _list;
  String? _err;
  final _ref = TextEditingController();
  final _ttl = TextEditingController(text: '60');
  String _mode = 'otp';
  bool _once = true;
  bool _tg = false;
  bool _dc = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ref.text = appState.activeRef ?? '';
    _load();
  }

  @override
  void dispose() {
    _ref.dispose();
    _ttl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await api.watchList();
      if (mounted) {
        setState(() {
          _list = r;
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = errorText(e));
    }
  }

  Map<String, dynamic>? get _notify {
    final n = <String, dynamic>{
      if (_tg) 'telegram': true,
      if (_dc) 'discord': true,
    };
    return n.isEmpty ? null : n;
  }

  Future<void> _create() async {
    if (_ref.text.trim().isEmpty) {
      showError(context, 'Isi ref yang mau dipantau');
      return;
    }
    setState(() => _busy = true);
    try {
      await api.watchCreate(
        ref: _ref.text.trim(),
        mode: _mode,
        ttlMinutes: int.tryParse(_ttl.text.trim()),
        once: _once,
        notify: _notify,
      );
      if (mounted) showOk(context, 'Pantauan dibuat');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runNow() async {
    try {
      final r = await api.watchRun();
      if (!mounted) return;
      final reports = r is Map ? listOf(r['reports']) : const [];
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${reports.length} pantauan diperiksa'),
          content: SingleChildScrollView(child: JsonView(r)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Tutup'),
            ),
          ],
        ),
      );
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _testNotify() async {
    try {
      final r = await api.notifyTest(
        targets: _notify == null ? null : {'telegram': _tg, 'discord': _dc},
      );
      if (!mounted) return;
      final results = r is Map ? listOf(r['results']) : const [];
      final text = results
          .map(
            (x) => x is Map
                ? '${x['channel']}: ${x['ok'] == true ? 'ok' : x['error'] ?? 'gagal'}'
                : x.toString(),
          )
          .join(' • ');
      showOk(context, text.isEmpty ? 'Tidak ada kanal notifikasi aktif' : text);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(Map w) async {
    final id = w['id']?.toString();
    if (id == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Hapus pantauan?',
      body:
          'Pantauan untuk ${w['address'] ?? w['ref'] ?? id} dihentikan dan tidak mengirim notifikasi lagi.',
    );
    if (!ok) return;
    try {
      await api.watchDelete(id);
      if (mounted) showOk(context, 'Pantauan dihapus');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final items = listOf(_list, ['items', 'watches']);
    final ch = _list is Map && _list['channels'] is Map
        ? _list['channels'] as Map
        : null;
    String st(dynamic v) => v == true ? 'siap' : 'belum diatur';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pantauan & notifikasi'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (ch != null) ...[
            Text(
              'Telegram: ${st(ch['telegram'])} • Discord: ${st(ch['discord'])}'
              '${ch.containsKey('webhook_signing') ? ' • Tanda tangan webhook: ${ch['webhook_signing'] == true ? 'aktif' : 'nonaktif'}' : ''}',
              style: TextStyle(color: s.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _ref,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Ref yang dipantau (alias / alamat)',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'otp', label: Text('OTP')),
                  ButtonSegment(value: 'link', label: Text('Link')),
                ],
                selected: {_mode},
                onSelectionChanged: (v) => setState(() => _mode = v.first),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _ttl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Durasi (menit)',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('Sekali saja'),
                selected: _once,
                onSelected: (v) => setState(() => _once = v),
              ),
              FilterChip(
                label: const Text('Telegram'),
                selected: _tg,
                onSelected: (v) => setState(() => _tg = v),
              ),
              FilterChip(
                label: const Text('Discord'),
                selected: _dc,
                onSelected: (v) => setState(() => _dc = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _create,
            icon: const Icon(Icons.add_alert_outlined),
            label: const Text('Buat pantauan'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _runNow,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Jalankan'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testNotify,
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('Tes notifikasi'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _heading('Pantauan aktif'),
          if (_err != null && _list == null)
            Text(_err!, style: TextStyle(color: s.error))
          else if (_list == null)
            const Center(child: CircularProgressIndicator())
          else if (items.isEmpty)
            const Text('Belum ada pantauan.')
          else
            for (final w in items)
              Card(
                child: ListTile(
                  title: Text(
                    w is Map
                        ? (w['address'] ?? w['ref'] ?? '').toString()
                        : w.toString(),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: w is Map
                      ? Text(
                          [
                            'mode: ${w['mode'] ?? '-'}',
                            if (w['fired'] != null) 'terkirim ${w['fired']}×',
                            if (w['expires_at'] != null)
                              'berakhir ${fmtTime(w['expires_at'])}',
                            if (w['once'] == true) 'sekali',
                            if (w['last_error'] != null)
                              'galat: ${w['last_error']}',
                          ].join(' • '),
                        )
                      : null,
                  trailing: w is Map && w['id'] != null
                      ? IconButton(
                          tooltip: 'Hapus pantauan',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(w),
                        )
                      : null,
                ),
              ),
        ],
      ),
    );
  }
}

// ============================ DEBUG ============================
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});
  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final _ref = TextEditingController();
  dynamic _result;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ref.text = appState.activeRef ?? '';
  }

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_ref.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final r = await api.debugRef(_ref.text.trim(), inbox: true);
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug upstream'),
        actions: [
          if (_result != null)
            IconButton(
              tooltip: 'Salin JSON',
              onPressed: () =>
                  copyText(context, _pretty(_result), 'JSON disalin'),
              icon: const Icon(Icons.copy),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ref,
            autocorrect: false,
            onSubmitted: (_) => _run(),
            decoration: const InputDecoration(labelText: 'Ref / alamat'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _run,
            child: Text(_busy ? 'Memeriksa…' : 'Jalankan diagnosis'),
          ),
          if (_result != null) ...[
            const SizedBox(height: 14),
            JsonView(_result),
          ],
        ],
      ),
    );
  }
}

// ============================ ADMIN ============================
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  dynamic _view;
  String _title = '';

  Future<void> _show(String title, Future<dynamic> Function() fn) async {
    try {
      final r = await fn();
      if (mounted) {
        setState(() {
          _title = title;
          _view = r;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _confirmRun(
    String title,
    String body,
    String done,
    Future<dynamic> Function() fn,
  ) async {
    final ok = await confirmDialog(
      context,
      title: title,
      body: body,
      confirmLabel: 'Lanjut',
    );
    if (!ok) return;
    try {
      await fn();
      if (mounted) showOk(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _editJson(
    String title,
    Future<dynamic> Function() load,
    Future<dynamic> Function(dynamic) save,
  ) async {
    dynamic cur;
    try {
      cur = await load();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    final ctl = TextEditingController(text: _pretty(cur));
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctl,
            maxLines: 16,
            autocorrect: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    final text = ctl.text;
    if (ok != true) return;
    try {
      final parsed = jsonDecode(text);
      final r = await save(parsed);
      if (mounted) {
        showOk(context, 'Tersimpan');
        setState(() {
          _title = title;
          _view = r;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Log ditampilkan sebagai baris teks seperti di web, bukan JSON mentah.
  Widget _viewBody() {
    final v = _view;
    final logs = v is Map ? v['logs'] : null;
    if (logs is List) {
      if (logs.isEmpty) return const Text('(log kosong)');
      final lines = logs
          .map((l) {
            if (l is! Map) return l.toString();
            final ts = (l['ts'] ?? '').toString();
            final t = ts.length >= 19 ? ts.substring(11, 19) : ts;
            final data = l['data'] == null ? '' : ' ${jsonEncode(l['data'])}';
            return '$t ${(l['level'] ?? '').toString().toUpperCase()} ${l['msg'] ?? ''}$data';
          })
          .join('\n');
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          lines,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      );
    }
    return JsonView(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _show('Log server', () => api.adminLogs()),
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('Lihat log'),
              ),
              OutlinedButton.icon(
                onPressed: () => _confirmRun(
                  'Bersihkan log?',
                  'Log ring-buffer server dikosongkan.',
                  'Log dibersihkan',
                  api.adminClearLogs,
                ),
                icon: const Icon(Icons.clear_all, size: 18),
                label: const Text('Bersih log'),
              ),
              OutlinedButton.icon(
                onPressed: () => _show('Config', () => api.adminConfig()),
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('Config'),
              ),
              OutlinedButton.icon(
                onPressed: () => _show('Reload', () => api.adminReload()),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reload'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.language),
            title: const Text('Domain kustom (grup)'),
            subtitle: const Text('GET / PUT / DELETE /admin/domains'),
            trailing: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Ubah',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editJson(
                    'Domain kustom {"groups": {...}}',
                    () => api.adminDomains(),
                    (v) async {
                      if (v is! Map) {
                        throw const FormatException('harus berupa objek JSON');
                      }
                      final groups = v['groups'] is Map
                          ? (v['groups'] as Map).cast<String, dynamic>()
                          : v.cast<String, dynamic>();
                      return api.adminPutDomains(groups);
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Reset',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmRun(
                    'Reset domain kustom?',
                    'Domain kustom dikembalikan ke bawaan.',
                    'Domain kustom direset',
                    api.adminDeleteDomains,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.pin_outlined),
            title: const Text('Pola OTP kustom'),
            subtitle: const Text('GET / PUT / DELETE /admin/otp-patterns'),
            trailing: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Ubah',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editJson(
                    'Pola OTP (array pola)',
                    () => api.adminOtpPatterns(),
                    (v) => api.adminPutOtpPatterns(
                      v is Map && v['patterns'] != null ? v['patterns'] : v,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Reset',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmRun(
                    'Reset pola OTP kustom?',
                    'Pola OTP dikembalikan ke bawaan.',
                    'Pola OTP direset',
                    api.adminDeleteOtpPatterns,
                  ),
                ),
              ],
            ),
          ),
          if (_view != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _heading(_title)),
                IconButton(
                  tooltip: 'Salin',
                  onPressed: () => copyText(context, _pretty(_view)),
                  icon: const Icon(Icons.copy, size: 18),
                ),
              ],
            ),
            _viewBody(),
          ],
        ],
      ),
    );
  }
}

// ============================ TENTANG ============================
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  dynamic _me;
  dynamic _health;
  String? _healthErr;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final h = await api.health();
      if (mounted) {
        setState(() {
          _health = h;
          _healthErr = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _healthErr = errorText(e));
    }
    try {
      final m = await api.me();
      if (mounted) setState(() => _me = m);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final h = _health;
    final online = _healthErr == null && h != null;
    final checking = _loading && h == null && _healthErr == null;
    final up = h is Map && h['upstream'] is Map ? h['upstream'] as Map : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tentang & status'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loading ? null : _load,
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
                  leading: Icon(
                    checking
                        ? Icons.hourglass_top
                        : online
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: checking
                        ? null
                        : online
                        ? Colors.green
                        : s.error,
                  ),
                  title: Text(
                    checking
                        ? 'Memeriksa server…'
                        : online
                        ? 'Server online'
                        : 'Server tidak terjangkau',
                  ),
                  subtitle: Text(
                    _healthErr ??
                        (up != null
                            ? 'Upstream ${up['ok'] == true ? 'OK' : 'GAGAL'}'
                                  '${up['ms'] != null ? ' · ${up['ms']} ms' : ''}'
                                  '${h is Map && h.containsKey('kv') ? ' · KV ${h['kv'] == true || h['kv'] is Map ? 'OK' : 'GAGAL'}' : ''}'
                            : kApiBase),
                  ),
                ),
                ListTile(
                  leading: Icon(
                    kApiToken.isEmpty ? Icons.key_off_outlined : Icons.key,
                    color: kApiToken.isEmpty ? s.error : null,
                  ),
                  title: Text(
                    kApiToken.isEmpty
                        ? 'Token API belum disuntik'
                        : 'Token API terpasang',
                  ),
                  subtitle: const Text('Disuntik saat build via --dart-define'),
                ),
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: Text(
                    kAppBuild > 0
                        ? 'Versi aplikasi: b$kAppBuild'
                        : 'Versi aplikasi: build lokal',
                  ),
                  subtitle: const Text('Ketuk untuk cek pembaruan'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const UpdateScreen()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _heading('Server'),
          SelectableText(kApiBase),
          const SizedBox(height: 12),
          _heading('Health'),
          if (h != null) JsonView(h),
          const SizedBox(height: 12),
          _heading('Info server (/v1/me)'),
          if (_me != null) JsonView(_me),
        ],
      ),
    );
  }
}
