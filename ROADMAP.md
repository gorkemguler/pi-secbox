# Yol haritası

Sıra kabaca öncelik sırası. Bir maddeyi üstlenmek istersen issue açman yeterli.

## Tamamlananlar

- [x] Tek komutla kurulum, tekrar çalıştırılabilir (`setup.sh`)
- [x] Go derlemeden ProjectDiscovery araçları (pdtm, SHA256 doğrulamalı)
- [x] Yavaş bağlantıda nuclei şablonlarının git ile indirilmesi
- [x] ufw, fail2ban, proxychains4 ayarları
- [x] `pisec`: lan, scan, recon, web, Tor modu, kapsam listesi, sonuç klasörleri
- [x] Tor modunda DNS sızıntılarını kapatma (tor-resolve, testssl `--nodns none`)
- [x] Her çalıştırmaya ayrı Tor devresi (SOCKS kimliğiyle ayrıştırma)
- [x] Önceki çalıştırmayla karşılaştırma: yeni alt alan adları, yeni açılan portlar
- [x] Zamanlanmış taramalar (systemd timer)
- [x] ntfy bildirimleri
- [x] Cloudflare: geçici yayın ve kalıcı tünel
- [x] Web paneli: taramalar, sonuçlar, zamanlama, kapsam, Docker, yayınlama
- [x] `uninstall.sh`, bats ve panel testleri, CI

## Sıradakiler (0.3)

- [ ] **Rapor dışa aktarma.** Bir hedefin son çalıştırmalarından tek sayfalık HTML rapor;
      panelden indirme.
- [ ] **nuclei bulgularını JSON'dan okuma.** Panelde önem seviyesine göre filtre, şablon
      bağlantısı, aynı bulgunun önceki taramada olup olmadığı.
- [ ] **E-posta güvenliği kontrolü.** `pisec mail hedef.com`: SPF, DKIM seçicileri, DMARC,
      MTA-STS, MX sunucularında STARTTLS.
- [ ] **Sertifika takibi.** crt.sh üzerinden hedefe yeni sertifika çıkınca bildirim;
      zamanlanmış görev olarak.
- [ ] **İki aşamalı giriş.** Panel için TOTP.
- [ ] **Bookworm ve 32-bit testleri.** Pi Zero 2 W ve Pi 3 üzerinde kurulum ve bellek
      ölçümü.
- [ ] **MAC adresi rastgeleleştirme.** `pisec mac random|reset <arayüz>`; macchanger
      kurulu ama komutu yok. SSH'nin bağlı olduğu arayüzde uyarı vermeli.

## Daha sonra

- [ ] **Eğitim laboratuvarı şablonları.** OWASP Juice Shop, DVWA gibi bilerek açıklı
      uygulamalar için hazır compose dosyaları; sadece `127.0.0.1` ve kapsam listesine
      otomatik ekleme.
- [ ] **Hazır uygulama şablonları.** Uptime Kuma, AdGuard Home, Gitea için compose
      şablonları ve panelden tek tıkla kurulum.
- [ ] **WireGuard.** Pi'ye uzaktan erişim için Cloudflare'a alternatif; panelden eş ekleme
      ve QR kod.
- [ ] **Panelde geçmiş grafikleri.** Sıcaklık, açık port ve alt alan adı sayısının
      zamanla değişimi.
- [ ] **Pasif ağ izleme.** Yerel ağda yeni cihaz görülünce bildirim (`pisec lan` farkı
      üzerinden, ARP izleme ile).
- [ ] **Wi-Fi denetimi.** Monitor modu destekleyen USB adaptörle isteğe bağlı modül
      (aircrack-ng, hcxtools). Pi'nin dahili Wi-Fi'si monitor modunu desteklemiyor.
- [ ] **Bluetooth Low Energy keşfi.**
- [ ] **Hazır SD kart imajı.** pi-gen ile pi-secbox kurulu Raspberry Pi OS Lite imajı.
- [ ] **İngilizce arayüz.** CLI ve panel metinleri için çeviri dosyası.

## Fikir aşamasında

- Shodan, Censys gibi servislerden pasif keşif (API anahtarı varsa).
- Birden fazla Pi'yi tek panelden yönetme.
- Tor yerine başka çıkışlar: SOCKS proxy listesi, WireGuard çıkışı.
- Taramaların ekran görüntüsü (gowitness); Pi'de headless Chromium ağır, isteğe bağlı olmalı.
