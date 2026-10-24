// Pendeteksi OTP cadangan di sisi aplikasi, dipakai bila server tidak
// mengenali kodenya (mis. "08737 adalah kode konfirmasi Facebook Anda").
//
// Hanya angka 4–8 digit yang berada dekat kata kunci kode/OTP yang dianggap
// OTP, supaya tahun, tanggal, nomor telepon, atau nomor pesanan tidak salah
// terdeteksi.

final _keyword = RegExp(
  r'\b(otp|kode|code|codigo|código|pin|passcode|verifikasi|verification|'
  r'konfirmasi|confirmation|confirm|verify|token|sandi|password|login|masuk|'
  r'sekali\s+pakai|one[-\s]?time|security|keamanan|authentication|autentikasi)\b',
  caseSensitive: false,
);

// Kandidat: 4–8 digit (boleh dipisah spasi/tanda hubung di tengah, mis.
// "123 456" / "123-456"), atau format Google "G-123456".
final _candidate = RegExp(
  r'(?<![\w+#./:-])(?:G-)?(\d{3,4}[ -]\d{3,4}|\d{4,8})(?![\w/:]|[.,]\d|-\d)',
);

/// Kode OTP dari subjek/isi email, atau null bila tidak yakin.
String? detectOtp({String? subject, String? text}) {
  String? best;
  var bestScore = 0;
  void scan(String? src, int base) {
    if (src == null || src.trim().isEmpty) return;
    for (final m in _candidate.allMatches(src)) {
      final raw = m.group(1)!;
      final code = raw.replaceAll(RegExp(r'[ -]'), '');
      if (code.length < 4 || code.length > 8) continue;
      // Tahun (1900–2099) tanpa kata kunci di dekatnya hampir pasti bukan OTP.
      final n = int.tryParse(code) ?? 0;
      final looksYear = code.length == 4 && n >= 1900 && n <= 2099;
      final from = (m.start - 48).clamp(0, src.length);
      final to = (m.end + 48).clamp(0, src.length);
      final near = src.substring(from, to);
      if (!_keyword.hasMatch(near)) continue;
      var score = base;
      if (m.group(0)!.startsWith('G-')) score += 3;
      if (code.length == 6) score += 2;
      if (code.length >= 5) score += 1;
      if (looksYear) score -= 4;
      // Kode di awal subjek ("08737 adalah kode …") sangat khas.
      if (base >= 10 && m.start <= 2) score += 3;
      if (score > bestScore) {
        bestScore = score;
        best = code;
      }
    }
  }

  scan(subject, 10);
  scan(text, 5);
  return bestScore >= 5 ? best : null;
}

/// OTP sebuah pesan: dari server bila ada, jika tidak dari [detectOtp].
/// Mengembalikan (kode, dari server?).
(String, bool)? messageOtp(Map m) {
  final s = m['otp']?.toString();
  if (s != null && s.isNotEmpty) return (s, true);
  final c = detectOtp(
    subject: m['subject']?.toString(),
    text: (m['text'] ?? m['preview'])?.toString(),
  );
  return c == null ? null : (c, false);
}
