# pisec

`pisec`, pi-secbox'taki araçları doğru bayraklarla çalıştıran bir bash betiği.
`setup.sh` onu `/usr/local/bin/pisec` olarak kuruyor. Tüm seçenekler için `pisec --help`.

Argümansız `pisec` çalıştırınca hedefi ve Tor tercihini soran bir menü açılır.

## Komutlar

| Komut | Ne yapıyor |
|---|---|
| `tor status` | Tor servisinin durumu, Tor çıkış IP'si, gerçek IP, kontrol soketine erişim |
| `tor new` | Tor'a `NEWNYM` sinyali gönderir; sonraki bağlantılar yeni devrelerden çıkar |
| `lan [ağ]` | Ağ verilmezse varsayılan rotanın ağını bulur. `sudo` ile ARP taraması yapar, cihazları MAC adresi ve üreticiyle listeler |
| `scan <hedef>` | nmap. Varsayılan: servis tespiti, en sık 1000 port. `-p`, `--top` ve `--` sonrası nmap seçeneklerini kabul eder |
| `recon <alan-adı>` | subfinder (pasif kaynaklar) → dnsx → httpx |
| `web <url>` | HTTP güvenlik başlıkları, testssl.sh, nuclei (varsayılan önem: low ve üstü) |
| `scope` | İzinli hedef listesi: `scope add`, `scope rm`, `scope check` |
| `results [hedef]` | Kayıtlı sonuçları listeler, hedef verilirse son özeti gösterir |
| `schedule` | Zamanlanmış taramalar: `schedule add`, `schedule rm`, `schedule run` |
| `notify` | ntfy bildirimleri: `notify set <url>`, `notify off`, `notify test` |
| `publish <port>` | `127.0.0.1:<port>`'u geçici bir `trycloudflare.com` adresinden açar; `publish list`, `publish stop <port>` |
| `tunnel` | Cloudflare hesabına bağlı kalıcı tünel: `tunnel token`, `tunnel start`, `tunnel stop` |
| `panel` | Web paneli: `panel passwd`, `panel start`, `panel stop` |

```bash
pisec scan hedef.com -p 22,80,443
pisec scan 192.168.1.10 -- -sC            # "--" sonrası nmap'e olduğu gibi gider
pisec web https://hedef.com -s high,critical
pisec web https://hedef.com --no-nuclei   # sadece başlıklar ve TLS
```

## `--tor` ne değiştiriyor

| | Tor'suz | `--tor` ile |
|---|---|---|
| nmap | `-sV -T4 --top-ports 1000` | proxychains üzerinden `-sT -Pn -n --top-ports 100`; ham soket isteyen seçenekler (`-sS`, `-sU`, `-O`, ping) reddedilir |
| Alan adı çözümü | yerel DNS | `tor-resolve` ile Tor üzerinden; nmap'e ve testssl'e IP verilir |
| testssl.sh | doğrudan | proxychains üzerinden, `--ip` ve `--nodns none` ile; testssl kendi DNS sorgusunu yapmaz |
| nuclei | tüm şablonlar | sadece HTTP şablonları (`-pt http`), interactsh kapalı (`-ni`), SOCKS5 proxy |
| subfinder, httpx | doğrudan | SOCKS5 proxy; subfinder'ın crt.sh kaynağı kapalı (veritabanına proxy'siz bağlanıyor) |
| dnsx | çalışır | atlanır, DNS sorgularını kendisi yapıyor |
| Yerel ağ, özel adresler | taranır | reddedilir, Tor çıkışları senin ağına ulaşamaz |

Her `pisec` çalıştırması Tor'a farklı bir SOCKS kullanıcı adıyla bağlanır. Tor bu
bağlantıları ayrı devrelerden geçiriyor (`IsolateSOCKSAuth`), yani iki tarama aynı
çıkış IP'sini paylaşmaz. `pisec` kendi proxychains ayarını geçici bir dosyaya yazıyor;
`/etc/proxychains4.conf`'a bağlı değil. ProjectDiscovery araçlarının açılıştaki
sürüm kontrolü (`api.pdtm.sh`) her modda kapalı.

Pi 4 üzerinde, Tor modundaki `scan`, `web` ve `recon` çalışırken Pi'den çıkan DNS
trafiği tcpdump ile kaydedildi: hedef alan adları için hiç DNS sorgusu çıkmadı.

Tor üzerinden tarama yavaştır ve çoğu çıkış noktası 25, 445 gibi portlara izin vermez.
Cloudflare arkasındaki pek çok site Tor çıkışlarını engelliyor; nuclei'nin Tor ile
"bulgu yok" demesi hedefin temiz olduğu anlamına gelmiyor.

`tor new` için kullanıcının `debian-tor` grubunda olması gerekiyor (`setup.sh` ekliyor).
Tor'un Debian paketi kontrol soketini (`/run/tor/control`) ve çerez dosyasını bu gruba
açıyor.

## Kapsam listesi

`~/.config/pisec/kapsam` dosyası test etme iznin olan hedefleri tutar. Her satıra bir
alan adı (alt alan adlarını da kapsar), IPv4 adresi ya da CIDR ağı yazılır:

```
hedef.com
203.0.113.0/24
192.168.1.0/24
```

```bash
pisec scope add hedef.com 203.0.113.0/24
pisec scope check https://api.hedef.com    # kapsamda mı? (çıkış kodu 0/1)
pisec scope rm hedef.com
```

Listede olmayan hedefte `pisec` devam etmeden önce "evet" yazmanı ister. Terminal
yoksa (betik, panel, zamanlanmış görev) hiç başlamaz. Betik içinden bilerek atlamak
istersen `-y` ver; özet dosyasına "listede değil, -y ile devam edildi" yazılır.
`kotuhedef.com`, `hedef.com` girdisine uymaz; eşleşme nokta sınırında yapılıyor.

## Sonuçlar

Her çalıştırma `~/pisec-sonuclar/<hedef>/<tarih>-<komut>/` altında bir klasör açar:

- `ozet.md`: tarih, Tor çıkış IP'si, kapsam durumu ve bulguların özeti
- `komutlar.txt`: çalıştırılan komutların tam hali
- aracın kendi çıktıları: `nmap.nmap/.gnmap/.xml`, `subdomains.txt`, `dns.txt`,
  `web.txt`, `headers.txt`, `testssl.json`, `testssl.log`, `nuclei.txt`

`recon` ve `scan`, aynı hedefin bir önceki çalıştırmasıyla karşılaştırma yapar ve
özetin sonuna ekler:

```
## Önceki çalıştırmaya göre (20261029-030044-recon)

Yeni alt alan adları:

- staging.hedef.com
```

## Zamanlanmış taramalar

```bash
pisec schedule add daily recon hedef.com
pisec schedule add "Mon *-*-* 03:00" scan hedef.com --tor --name haftalik-port
pisec schedule add hourly lan 192.168.1.0/24
pisec schedule                 # liste, sonraki ve son çalışma zamanı
pisec schedule run haftalik-port
pisec schedule rm haftalik-port
```

Zaman, systemd'nin [OnCalendar](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html#Calendar%20Events)
söz dizimiyle yazılıyor: `daily`, `weekly`, `hourly`, `"*-*-* 02:30"`,
`"Sat *-*-* 04:00"`. Her görev `~/.config/systemd/user` altında bir `.service` ve bir
`.timer` dosyası. Pi kapalıyken kaçırılan çalıştırma açılışta yapılıyor
(`Persistent=true`). Kullanıcı oturumu kapalıyken de çalışmaları için linger açık
olmalı; `setup.sh` açıyor.

Zamanlanmış görev onay soramadığı için hedefin kapsam listesinde olması gerekiyor;
sonradan listeden çıkarılırsa görev bir sonraki çalışmada hata verip durur.
Çıktısını görmek için: `journalctl --user-unit pisec-job-<ad>`.

## Bildirimler

```bash
pisec notify set https://ntfy.sh/pisec-a8f3k2
pisec notify test
```

Tarama bitince başlık ve kısa bir özet (açık port sayısı, yeni alt alan adları, TLS ve
nuclei bulgu sayıları) [ntfy](https://ntfy.sh) konusuna gönderilir. Telefona ntfy
uygulamasını kur, aynı konuya abone ol. ntfy.sh'ta konuyu bilen herkes mesajları
okuyabildiği için tahmin edilmesi zor bir ad seç ya da kendi ntfy sunucunu kullan;
erişim token'ı gerekiyorsa `pisec notify set <url> <token>`.

Ayar `~/.config/pisec/config` dosyasında duruyor (izinler 600). Tek bir çalıştırmada
bildirimi kapatmak için `PISEC_NOTIFY=0 pisec ...`.

## Cloudflare ile yayınlama

Pi'de çalışan bir web uygulamasını modemde port açmadan dışarıya açmanın iki yolu var.
İkisi de `cloudflared` istiyor: `./setup.sh --with-cloudflared`.

**Geçici adres** (hesap gerekmez):

```bash
pisec publish 8081            # onay ister, sonra adresi yazar
pisec publish                 # yayındakiler
pisec publish stop 8081
```

`cloudflared tunnel --url` ile rastgele bir `*.trycloudflare.com` adresi alır. Tünel
`systemd-run` ile bir kullanıcı birimi olarak çalışıyor; terminali kapatsan da açık
kalıyor, Pi yeniden başlayınca kapanıyor. Adresi bilen herkes erişebilir. Panelin portu
bu yolla yayınlanmıyor; giriş sayfasını rastgele bir adresle internete açmak istemeyiz.

**Kalıcı tünel** (Cloudflare hesabı ve Cloudflare'da yönetilen bir alan adı):

```bash
pisec tunnel token            # Zero Trust panelinden aldığın token'ı yapıştır
pisec tunnel start
```

Hangi alt alan adının Pi'deki hangi porta gideceği Cloudflare Zero Trust panelinden
ayarlanıyor. Paneli bu yolla açmak için: [docs/panel.md](panel.md#cloudflare-tunnel-ve-access).

## Ortam değişkenleri

Testler ve özel kurulumlar için:

| Değişken | Varsayılan |
|---|---|
| `PISEC_OUT` | `~/pisec-sonuclar` |
| `PISEC_SCOPE` | `~/.config/pisec/kapsam` |
| `PISEC_CONF_DIR` | `~/.config/pisec` |
| `PISEC_STATE` | `~/.local/state/pisec` |
| `PISEC_SOCKS` | `127.0.0.1:9050` |
| `PISEC_NOTIFY` | `1` (`0` bildirim göndermez) |
