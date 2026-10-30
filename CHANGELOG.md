# Değişiklikler

Biçim [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/) düzenine yakın,
sürümler [Semantic Versioning](https://semver.org/lang/tr/) ile numaralanıyor.

## [0.2.0] - 2026-10-30

### Eklenenler

- `pisec` komutu: `lan`, `scan`, `recon`, `web`, `tor`, `scope`, `results` ve
  argümansız çalıştırınca açılan menü.
- Tor modu: nmap proxychains üzerinden connect taramasıyla, alan adları `tor-resolve`
  ile çözülüyor, testssl.sh'ın DNS sorguları kapatılıyor, nuclei sadece HTTP
  şablonlarıyla ve interactsh kapalı çalışıyor. Her çalıştırma ayrı bir Tor devresi
  kullanıyor. Ham soket isteyen nmap seçenekleri ve özel adresler reddediliyor.
  `tor-resolve` bir adı çözemezse sorgu Tor üzerinden DNS-over-HTTPS ile yapılıyor.
  subfinder'ın proxy'siz bağlanan crt.sh kaynağı ve ProjectDiscovery araçlarının
  sürüm kontrolü kapalı. Pi 4'te tcpdump ile denendi: hedefler için DNS sorgusu çıkmıyor.
- Kapsam listesi (`~/.config/pisec/kapsam`).
- Her çalıştırma için sonuç klasörü, `ozet.md` ve `komutlar.txt`.
- `recon` ve `scan` önceki çalıştırmayla karşılaştırma yapıyor.
- Zamanlanmış taramalar: `pisec schedule` (systemd kullanıcı zamanlayıcıları).
- ntfy bildirimleri: `pisec notify`.
- Cloudflare: `pisec publish` (geçici `trycloudflare.com` adresi) ve `pisec tunnel`
  (token ile kalıcı tünel).
- Web paneli (`setup.sh --with-panel`): taramalar ve canlı çıktı, sonuçlar, zamanlama,
  kapsam, Docker, yayınlama, sistem işlemleri. Demo modu (`panel/demo/run.sh`).
- `setup.sh --with-docker`, `--with-cloudflared`, `--all`.
- `uninstall.sh`, `--dry-run`, `--packages`, `--purge` seçenekleriyle.
- bats testleri, panel testleri; CI'da shellcheck, bats ve panel testleri.
- Banner, ekran görüntüleri, İngilizce README, yol haritası, güvenlik politikası.

### Değişenler

- Linger artık her kurulumda açılıyor; zamanlanmış görevler ve panel oturum kapalıyken
  de çalışıyor.
- Kullanıcı `debian-tor` grubuna ekleniyor (`pisec tor new` için).

## [0.1.0] - 2026-10-30

İlk sürüm: `setup.sh`, komut notları ve README. Raspberry Pi 4 üzerindeki ilk testten
sonra şunlar düzeltildi:

- proxychains ayarı `proxy_dns_daemon` satırını da açıyordu, her bağlantı zaman aşımına
  düşüyordu.
- nuclei şablonları yavaş bağlantıda 30 saniyelik sabit süre sınırına takılıp hiç
  inmiyordu; artık git ile çekiliyor.
- ufw kurulup açılmıyordu; fail2ban Debian 12'de başlamıyordu.
- Komut notları `~/README.md`'nin üzerine yazılıyordu.
- Go derleyicisi yerine pdtm'nin SHA256 doğrulamalı hazır binary'si kullanılıyor.
- apt kurulumları debconf sorularında takılıyordu.

[0.2.0]: https://github.com/gorkemguler/pi-secbox/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gorkemguler/pi-secbox/releases/tag/v0.1.0
