import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tempmail/main.dart';
import 'package:tempmail/screens_main.dart';

void main() {
  group('helper waktu & data', () {
    test('parseApiTime: tanpa zona dianggap UTC', () {
      final d = parseApiTime('2026-10-20 16:04:48')!;
      expect(d.isUtc, isTrue);
      expect(d.hour, 16);
      expect(parseApiTime('2026-10-20T16:04:48+07:00')!.toUtc().hour, 9);
      expect(parseApiTime(''), isNull);
      expect(parseApiTime(null), isNull);
    });

    test('initialOf aman untuk string kosong', () {
      expect(initialOf(''), '?');
      expect(initialOf(null), '?');
      expect(initialOf('"budi" <b@x.com>'), 'B');
      expect(initialOf('noreply@x.com'), 'N');
    });

    test('agoText', () {
      expect(agoText(10), 'baru saja');
      expect(agoText(120), '2 mnt lalu');
      expect(agoText(7200), '2 jam lalu');
      expect(agoText(null), '');
    });

    test('listOf menerima List atau Map berisi kunci', () {
      expect(listOf([1, 2]), [1, 2]);
      expect(
        listOf({
          'items': [1],
        }),
        [1],
      );
      expect(
        listOf(
          {
            'messages': [3],
          },
          ['messages'],
        ),
        [3],
      );
      expect(listOf(null), isEmpty);
      expect(listOf('x'), isEmpty);
    });

    test('quickGroupCounts cocokkan nama grup secara longgar', () {
      final c = quickGroupCounts(
        {
          'groups': [
            {'name': 'Premium ', 'count': 23},
            {'name': 'basic', 'count': 105},
            {'name': 'standard', 'count': '75'},
          ],
        },
        ['premium', 'basic', 'standard', 'semua'],
      );
      expect(c, {'premium': 23, 'basic': 105, 'standard': 75, 'semua': 203});
      expect(quickGroupCounts(null, ['premium']), isEmpty);
    });

    test('status favorit dibagi & tidak peka huruf besar', () {
      setFavoritesFrom([
        {'address': 'Graydon@Fantatua.com'},
        {'ref': 'tanpa-address'},
      ]);
      expect(isFavorite('graydon@fantatua.com'), isTrue);
      expect(isFavorite('lain@x.com'), isFalse);
      markFavorite('lain@x.com', true);
      expect(isFavorite('LAIN@x.com'), isTrue);
      markFavorite('graydon@fantatua.com', false);
      expect(isFavorite('graydon@fantatua.com'), isFalse);
      setFavoritesFrom([]);
    });

    test('msgTimeShort pakai umur pesan bila ada', () {
      expect(msgTimeShort({'age_seconds': 300}), '5 mnt lalu');
      expect(msgTimeShort({}), '');
    });
  });

  testWidgets('aplikasi tampil & tab OTP ikut alamat aktif', (tester) async {
    await tester.pumpWidget(const TempMailApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('TempMail'), findsWidgets);
    expect(find.text('Buat cepat'), findsOneWidget);

    // Beranda bisa di-refresh: tombol di AppBar + tarik ke bawah.
    expect(find.byTooltip('Muat ulang'), findsOneWidget);
    await tester.tap(find.byTooltip('Muat ulang'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.fling(find.text('Buat cepat'), const Offset(0, 400), 1000);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RefreshIndicator), findsWidgets);

    // Tab OTP tanpa alamat aktif.
    await tester.tap(find.text('OTP').last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Belum ada mailbox aktif'), findsWidgets);

    // Alamat aktif berganti → tab OTP langsung ikut (dulu tetap kosong).
    await tester.runAsync(() => appState.setActive('a@b.com', 'a@b.com'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('a@b.com'), findsWidgets);
    expect(find.text('OTP terbaru'), findsWidgets);

    // Inbox: request gagal (HTTP dimatikan di test) → tampil pesan galat,
    // bukan crash.
    await tester.tap(find.text('Inbox').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(InboxScreen), findsOneWidget);

    // Beranda: tombol Favorit mengikuti daftar favorit.
    await tester.tap(find.text('Beranda').last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Favoritkan'), findsOneWidget);
    setFavoritesFrom([
      {'address': 'A@B.com'},
    ]);
    await tester.pump();
    expect(find.text('Favoritkan'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Favorit'), findsOneWidget);
    setFavoritesFrom([]);

    await tester.runAsync(() => appState.clearActive());
    await tester.pump(const Duration(milliseconds: 100));
    // Bersihkan widget (dan timer/animasi) sebelum test selesai.
    await tester.pumpWidget(const SizedBox());
  });
}
