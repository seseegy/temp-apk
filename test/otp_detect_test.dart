import 'package:flutter_test/flutter_test.dart';

import 'package:tempmail/otp_detect.dart';

void main() {
  group('detectOtp: terdeteksi', () {
    final cases = <String, (String?, String?)>{
      '08737': ('08737 adalah kode konfirmasi Facebook Anda', null),
      '482913': ('Kode verifikasi Shopee', 'Gunakan kode 482913 untuk masuk.'),
      '123456': ('G-123456 is your Google verification code', null),
      '7741': ('Your code', 'Your one-time code is 7741.'),
      '559201': ('Login', 'Kode OTP Anda: 559 201. Jangan bagikan.'),
      '88123412': ('Verify your email', 'Enter this code: 88123412'),
      '004512': ('Konfirmasi akun', 'Masukkan PIN 004512 di aplikasi'),
    };
    cases.forEach((expected, input) {
      test(expected, () {
        expect(detectOtp(subject: input.$1, text: input.$2), expected);
      });
    });
  });

  group('detectOtp: tidak salah deteksi', () {
    final cases = <String, (String?, String?)>{
      'tahun': ('Laporan tahunan 2026', 'Ringkasan aktivitas sepanjang 2025.'),
      'tanggal': ('Jadwal', 'Pertemuan pada 22/10/2026 pukul 10:30.'),
      'telepon': ('Hubungi kami', 'Telepon +6281234567890 atau email kami.'),
      'pesanan': (
        'Pesanan dikirim',
        'Pesanan #12345678 sedang dalam perjalanan.',
      ),
      'tanpa kata kunci': (
        'Selamat datang',
        'Terima kasih, ada 12345 pengguna.',
      ),
      'url': ('Info', 'Buka https://x.com/a/99887766/b untuk detail login.'),
      'kosong': (null, null),
    };
    cases.forEach((name, input) {
      test(name, () {
        expect(detectOtp(subject: input.$1, text: input.$2), isNull);
      });
    });
  });

  test('messageOtp: utamakan OTP dari server', () {
    expect(messageOtp({'otp': '111222', 'subject': '333444 adalah kode'}), (
      '111222',
      true,
    ));
    expect(messageOtp({'subject': '08737 adalah kode konfirmasi Facebook'}), (
      '08737',
      false,
    ));
    expect(messageOtp({'subject': 'Halo', 'preview': 'apa kabar'}), isNull);
  });
}
