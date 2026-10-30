# pi-secbox komut notları

Bu dosya `setup.sh` tarafından `~/pisecbox-cheatsheet.md` olarak kopyalanır.
Okumak için: `less ~/pisecbox-cheatsheet.md`

`hedef.com` gördüğün her yerde, sahibi olduğun ya da test izni aldığın bir hedef kullan.

## pisec

Aşağıdaki araçların çoğunu doğru bayraklarla tek komuttan çalıştırır, sonuçları
`~/pisec-sonuclar` altına kaydeder.

```bash
pisec                                   # menü
pisec scope add hedef.com               # izinli hedef listesine ekle
pisec tor status                        # Tor durumu ve çıkış IP'si
pisec tor new                           # yeni devre
pisec lan                               # yerel ağdaki cihazlar
pisec scan hedef.com [--tor]            # port taraması
pisec scan hedef.com -p 22,80 -- -sC    # belirli portlar, ek nmap seçenekleri
pisec recon hedef.com [--tor]           # alt alan adları, canlı web servisleri
pisec web https://hedef.com [--tor]     # başlıklar, testssl, nuclei
pisec results hedef.com                 # son özet
pisec schedule add daily recon hedef.com    # her gece keşif
pisec schedule                          # zamanlanmış görevler
pisec notify set https://ntfy.sh/<konu> # tarama bitince telefona bildirim
pisec publish 8081                      # 127.0.0.1:8081'i geçici bir adresten aç
pisec publish stop 8081
pisec panel                             # web paneli durumu
```

Panel Pi'de `127.0.0.1:8090`'da. Başka bir bilgisayardan açmak için:
`ssh -L 8090:127.0.0.1:8090 kullanici@pisecbox.local`, sonra tarayıcıda `http://localhost:8090`.

## Tor

```bash
systemctl status tor@default                                  # asıl Tor süreci ("tor" servisi sadece sarmalayıcı)
curl -s https://check.torproject.org/api/ip                   # kendi IP'n
proxychains4 -q curl -s https://check.torproject.org/api/ip   # Tor çıkış IP'si, "IsTor":true görmelisin
pisec tor new                                                 # yeni devreler, büyük ihtimalle yeni çıkış IP'si
```

Tor sadece TCP taşır. UDP, ICMP ve ham soket kullanan her şey (ping, `nmap -sS`,
`dig` ile yapılan DNS sorguları) proxychains'i atlayıp doğrudan senin IP'nden çıkar.

## nmap (Tor üzerinden)

`-sT` (connect taraması), `-Pn` (ping yok) ve `-n` (ters DNS yok) üçü birlikte kullanılmalı.
Tor üzerinden tarama yavaştır, port listesini kısa tut.

```bash
proxychains4 -q nmap -sT -Pn -n -p 80,443,8080,8443 hedef.com
proxychains4 -q nmap -sT -Pn -n --top-ports 100 hedef.com
proxychains4 -q nmap -sT -Pn -n -sV -p 22,80,443 hedef.com
```

Yerel ağda Tor'a gerek yok:

```bash
sudo nmap -sn 192.168.1.0/24          # ayaktaki cihazlar
sudo nmap -sS -sV --top-ports 1000 192.168.1.10
```

## nuclei

nuclei SOCKS5 proxy'yi kendisi destekliyor, proxychains gerekmiyor.

```bash
nuclei -u https://hedef.com -proxy socks5://127.0.0.1:9050 -rl 30 -c 5
nuclei -u https://hedef.com -proxy socks5://127.0.0.1:9050 -s critical,high -rl 30
nuclei -ut                                                    # şablonları güncelle
```

Şablonlar `~/nuclei-templates` altında. Bağlantı yavaşsa `nuclei -ut` sessizce başarısız
olabiliyor; `setup.sh` bu durumda şablonları git ile çeker. Öyle kurulduysa güncellemek için
`git -C ~/nuclei-templates pull` kullan.

## subfinder, httpx, dnsx, naabu

```bash
subfinder -d hedef.com -silent | httpx -silent -title -status-code -proxy socks5://127.0.0.1:9050
subfinder -d hedef.com -silent | dnsx -silent -a -resp
naabu -host 192.168.1.10 -top-ports 100                       # yerel ağ; root olmadan connect taraması yapar
```

subfinder pasif kaynaklara (crt.sh, API'ler vb.) gider, hedefe dokunmaz. dnsx ve naabu
kendi DNS sorgularını yapar, bunları Tor'dan geçirmeye çalışma.

## TLS ve HTTP başlıkları

```bash
testssl hedef.com
testssl --severity HIGH hedef.com
proxychains4 -q curl -sI https://hedef.com
```

testssl, adres çözümlemesi için `dig`/`host` kullandığından proxychains ile birlikte
DNS sorguları Tor dışına çıkar. Tor üzerinden çalıştırmak için adresi önce Tor'dan çöz
ve testssl'in DNS sorgularını kapat (`pisec web --tor` bunu yapıyor):

```bash
ip=$(tor-resolve hedef.com)
proxychains4 -q testssl --ip "$ip" --nodns none https://hedef.com
```

## Araçları güncel tutmak

```bash
pdtm -ua                         # ProjectDiscovery araçları
nuclei -ut                       # nuclei şablonları (git ile kurulduysa: git -C ~/nuclei-templates pull)
sudo git -C /opt/testssl.sh pull # testssl.sh
sudo apt update && sudo apt full-upgrade
cd ~/pi-secbox && git pull && ./setup.sh --no-upgrade   # pisec ve betiklerin yeni sürümü
```

## Güvenlik duvarı ve fail2ban

```bash
sudo ufw status verbose
sudo ufw allow 8080/tcp                 # bir portu açmak için
sudo fail2ban-client status sshd        # banlanan IP'ler
sudo fail2ban-client set sshd unbanip 1.2.3.4
```

## tmux

Bağlantı koparsa tarama tmux içinde devam eder.

```bash
tmux new -s tarama      # yeni oturum
# Ctrl+B, ardından D    # oturumdan çık, arka planda çalışmaya devam etsin
tmux ls                 # açık oturumlar
tmux attach -t tarama   # geri dön
```
