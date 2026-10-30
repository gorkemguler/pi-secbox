# pi-secbox

Raspberry Pi OS Lite üzerine küçük bir ağ keşfi ve güvenlik denetimi araç seti kuran
bir kurulum betiği.

Kali ya da Parrot'u Pi'ye yazmak mümkün ama yüzlerce araç, masaüstü ortamı ve bir sürü
servisle geliyorlar. Pi'de bunun bedeli SD kart, RAM ve ısı olarak ödeniyor, araçların
çoğu da hiç açılmıyor. Burada yaklaşım tersi: temiz bir Raspberry Pi OS Lite kur,
`setup.sh` ile sadece gerçekten kullanılan araçları ekle.

## Neler kuruluyor

| Araç | Ne için |
|---|---|
| nmap, tcpdump, tshark | port taraması, paket yakalama |
| nuclei, subfinder, httpx, naabu, dnsx | ProjectDiscovery araçları, [pdtm](https://github.com/projectdiscovery/pdtm) ile hazır binary olarak |
| testssl.sh | TLS yapılandırma kontrolü (`/opt/testssl.sh`, 3.2 kararlı dalı) |
| whois, dnsutils | alan adı ve DNS sorguları |
| tor, torsocks, proxychains4 | trafiği komut bazında Tor'dan geçirmek |
| ufw, fail2ban | gelen bağlantıları kapatmak, SSH'ye kaba kuvvet denemelerini engellemek |
| macchanger | MAC adresi değiştirmek |
| tmux, git, curl, wget, jq | günlük işler |
| rpi-connect-lite | tarayıcıdan uzak terminal ([Raspberry Pi Connect](https://www.raspberrypi.com/software/connect/)) |

Paketlerin dışında betik şunları yapıyor:

- **ufw**: gelen bağlantıları kapatır, giden trafiğe dokunmaz. SSH portunu `sshd`
  ayarından okuyup açık bırakır (rate limit ile).
- **fail2ban**: sshd jail'ini journald'dan okuyacak şekilde ayarlar. Debian 12'de
  `/var/log/auth.log` olmadığı için varsayılan ayarla fail2ban başlamıyordu. Debian 13
  paketi bunu kendisi çözüyor, betik iki sürümde de aynı ayarı yazıyor.
- **proxychains4**: Tor'un SOCKS5 portuna (`127.0.0.1:9050`) yönlendirir, DNS
  sorgularını da proxy üzerinden yaptırır. Orijinal dosya `/etc/proxychains4.conf.orig`
  olarak saklanır.
- **nuclei şablonları**: önce `nuclei -ut` ile indirir. nuclei şablon arşivini 30
  saniyelik sabit bir süre sınırıyla indirdiği için yavaş bağlantıda bu adım hata
  vermeden boş bir dizin bırakabiliyor. Betik bunu fark ederse şablonları
  `git clone --depth 1` ile çeker ve nuclei'nin her açılışta tekrar güncellemeyi
  denememesi için `~/.config/nuclei/config.yaml` içinde `disable-update-check: true`
  ayarını açar.
- **PATH**: `~/.bashrc` sonuna pdtm'nin binary dizinini ekler.
- **Komut notları**: [`cheatsheet.md`](cheatsheet.md) dosyasını `~/pisecbox-cheatsheet.md`
  olarak kopyalar.

Betik tekrar çalıştırılabilir. İkinci çalıştırmada araçları ve testssl.sh'ı günceller,
`.bashrc`'ye ikinci kez satır eklemez.

## Gereksinimler

- 64-bit Raspberry Pi OS Lite. Debian tabanlı başka sistemlerde de çalışması gerekir,
  sadece Pi Connect adımı atlanır.
- `sudo` yetkisi olan normal bir kullanıcı. Betik root olarak çalıştırılırsa durur.
- İnternet bağlantısı ve SD kartta yaklaşık 1 GB boş alan. ProjectDiscovery araçları
  ~280 MB, nuclei şablonları ~100 MB, testssl.sh ~25 MB, geri kalanı apt paketleri.

Test edildiği ortam: Raspberry Pi 4 Model B (2 GB), Raspberry Pi OS Lite 64-bit
(Debian 13 Trixie), Wi-Fi. Bookworm ve 32-bit sistemlerde denenmedi.

## Kurulum

### 1. SD kartı hazırla

[Raspberry Pi Imager](https://www.raspberrypi.com/software/) ile **Raspberry Pi OS Lite
(64-bit)** yaz. Özelleştirme adımında:

- hostname ver (ör. `pisecbox`)
- kullanıcı adı ve parola belirle
- Wi-Fi kullanacaksan ağ adı, parola ve ülke kodunu gir
- SSH'yi aç, mümkünse parola yerine açık anahtar ile
- Imager sürümünde Raspberry Pi Connect seçeneği varsa onu da aç

Kartı takıp Pi'yi başlat, birkaç dakika sonra `ssh kullanici@pisecbox.local` ile bağlan.

### 2. Betiği çalıştır

```bash
git clone https://github.com/gorkemguler/pi-secbox.git
cd pi-secbox
./setup.sh
source ~/.bashrc
```

Seçenekler:

```
--no-upgrade    apt full-upgrade adımını atla
--no-firewall   ufw ayarlarına dokunma
```

Pi Connect'i Imager'da açmadıysan sonradan bağlayabilirsin:

```bash
rpi-connect on
rpi-connect signin
```

`signin` bir bağlantı verir, onu tarayıcıda açıp cihazı hesabına eklersin.

## Kullanım

Sık kullanılan komutlar [`cheatsheet.md`](cheatsheet.md) içinde. Birkaç örnek:

```bash
# Tor çalışıyor mu?
proxychains4 -q curl -s https://check.torproject.org/api/ip

# Tor üzerinden port kontrolü
proxychains4 -q nmap -sT -Pn -n -p 80,443 hedef.com

# Tor üzerinden nuclei
nuclei -u https://hedef.com -proxy socks5://127.0.0.1:9050 -s critical,high -rl 30

# Alt alan adları ve canlı web servisleri
subfinder -d hedef.com -silent | httpx -silent -title -status-code
```

Uzun süren taramaları `tmux` içinde başlat; SSH ya da Pi Connect bağlantısı koparsa
tarama devam eder.

## Bilmen gerekenler

**Tor sadece TCP taşır.** proxychains, programın açtığı TCP bağlantılarını Tor'a
yönlendirir. Ping, UDP ve ham soket kullanan her şey (`nmap -sS`, `nmap -sU`, `dig`)
doğrudan senin IP'nden çıkar. nmap'i Tor üzerinden kullanırken `-sT -Pn -n` üçlüsünü
unutma.

**Sistemin tüm trafiğini Tor'a zorlama.** iptables ile her şeyi Tor'a yönlendiren
araçlar (transparent proxy) Pi Connect'i koparır, çünkü Pi Connect WebRTC yani UDP
kullanıyor. Sadece çalıştırdığın komutu `proxychains4` ile ya da aracın kendi
`-proxy` seçeneğiyle Tor'dan geçir.

**testssl.sh DNS sızdırır.** Adres çözümlemesi için `dig`/`host` çağırdığından
proxychains ile çalıştırıldığında bile DNS sorguları Tor dışından gider.

**Güvenlik duvarı.** Pi üzerinde bir servis yayınlayacaksan portunu kendin aç:
`sudo ufw allow 8080/tcp`.

## İsteğe bağlı: Cloudflare Tunnel

Pi'deki bir web servisini modemde port açmadan dışarıya açmak için Cloudflare Tunnel
kullanılabilir. Hesap gerektirmeyen geçici tünel:

```bash
curl -fsSL -o cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
sudo dpkg -i cloudflared.deb

python3 -m http.server 8080 &
cloudflared tunnel --url http://localhost:8080
```

Komut, `trycloudflare.com` altında rastgele bir HTTPS adresi verir. Tünel giden
bağlantıyla kurulduğu için ufw'de port açmana gerek yok. Kalıcı bir adres için
Cloudflare hesabıyla isimli tünel kurman gerekir.

## Yasal uyarı

Bu araçları sadece sahibi olduğun ya da yazılı test izni aldığın sistemlerde kullan.
İzinsiz tarama ve zafiyet denetimi birçok ülkede suç.

## Lisans

[MIT](LICENSE)
