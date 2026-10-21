# TempMail (Aplikasi Android)

Klien Flutter untuk [rest-tempmail](https://github.com/seseegy/rest-tempmail) —
REST API tempmail pribadi di Cloudflare Workers. Semua endpoint API dipakai:
mailbox, inbox, OTP (terbaru/tunggu/stream/riwayat/ekstrak), link verifikasi,
favorit, varian titik/plus + Gmail, alias.md, domain, riwayat, pantauan &
notifikasi, debug, dan admin.

## Notifikasi & pembaruan

- **Notifikasi OTP**: saat "Tunggu OTP", stream, atau tunggu banyak alamat
  berjalan, aplikasi tetap menunggu walau ditinggal (foreground service,
  notifikasi status dengan tombol **Berhenti**). OTP yang masuk langsung
  disalin dan muncul sebagai notifikasi.
- **Pembaruan lewat APK** (Menu → Pembaruan aplikasi): versi terbaru dibaca
  dari GitHub Releases repo ini (`UPDATE_REPO`, otomatis dari CI). Unduhan
  berjalan di latar dan bisa dijeda/dilanjutkan/dibatalkan, diverifikasi
  ukuran + SHA-256, lalu dipasang lewat installer Android.
- **Widget layar utama** (tekan lama homescreen → Widget → TempMail):
  - *Alamat & OTP*: alamat aktif + OTP terbaru, tombol salin alamat/OTP,
    muat ulang, dan "Tunggu" (membuka aplikasi langsung menunggu OTP).
  - *Buat cepat*: premium / basic / standard / semua — alamat baru dibuat
    di latar, jadi aktif, dan langsung disalin.
- Pembaruan hanya bisa dipasang di atas versi yang **ditandatangani keystore
  yang sama** — pastikan secret `KEYSTORE_*` selalu terisi di CI.

## Keamanan token

Token API **tidak ada di kode**. Ia disuntik saat build:

```bash
flutter build apk --release \
  --dart-define=API_BASE=https://rest-tempmail.rosdiyttaa.workers.dev \
  --dart-define=API_TOKEN=<token>
```

Di GitHub Actions, token dibaca dari **Secrets** repo (`API_TOKEN`).

## Secrets yang dibutuhkan (Settings → Secrets and variables → Actions)

| Nama | Isi |
|---|---|
| `API_TOKEN` | Token API rest-tempmail |
| `KEYSTORE_BASE64` | Keystore release ter-encode base64 |
| `KEYSTORE_PASSWORD` | Password keystore |

## Build lokal

```bash
flutter pub get
flutter analyze && flutter test
flutter build apk --release --split-per-abi \
  --dart-define=API_TOKEN=<token>
```

Tanpa `android/key.properties`, APK release ditandatangani dengan kunci
debug (cukup untuk dicoba sendiri). CI selalu memakai keystore dari Secrets.

Paket: `com.rosdie.tempmail` • Min SDK 24 • Flutter 3.47.7
