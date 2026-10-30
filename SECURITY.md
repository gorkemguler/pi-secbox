# Güvenlik

## Açık bildirmek

pi-secbox'ta bir güvenlik açığı bulduysan (özellikle web panelinde) lütfen herkese açık
bir issue açma. GitHub'ın özel bildirim formunu kullan:
[Security → Report a vulnerability](https://github.com/gorkemguler/pi-secbox/security/advisories/new).

Bildirimde açığın nasıl tetiklendiğini, etkisini ve denediğin sürümü (`pisec --version`)
yaz. Düzeltme yayınlanana kadar ayrıntıları paylaşmamanı rica ederim.

Desteklenen sürüm `main` dalı ve en son etiketli sürüm.

## Kapsam

Kapsamda:

- Web paneli: kimlik doğrulama, oturum, CSRF, komut ya da argüman enjeksiyonu, dosya
  yolu aşımı, XSS.
- `pisec`: kapsam listesinin atlatılması, Tor modunda IP ya da DNS sızıntısı, ayar
  dosyalarının izinleri.
- `setup.sh` ve `uninstall.sh`: güvensiz indirme, yanlış izinler, beklenmedik dosya silme.

Kapsam dışı: nmap, nuclei, Tor gibi kurulan araçların kendi açıkları (ilgili projeye
bildir) ve Pi'ye zaten root ya da `docker` grubu yetkisiyle erişmiş birinin
yapabilecekleri.

## Tasarım

- Panel varsayılan olarak sadece `127.0.0.1`'de dinliyor ve serbest komut satırı
  sunmuyor. Ayrıntılar: [docs/panel.md](docs/panel.md#güvenlik).
- `pisec` dosya ayarlarını `source` etmiyor; `KEY=VALUE` satırları okunuyor.
- Token ve bildirim adresi gibi ayarlar `~/.config/pisec` altında 600 izinle duruyor.
- pdtm arşivi SHA256 ile doğrulanıyor; cloudflared Cloudflare'ın imzalı apt deposundan,
  Docker ve diğer paketler Debian depolarından geliyor.
