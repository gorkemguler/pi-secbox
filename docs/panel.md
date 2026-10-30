# Web paneli

`pisec`'in üstünde ince bir katman: tarama başlatma ve canlı izleme, sonuçlar,
zamanlanmış görevler, kapsam listesi, Docker konteynerleri ve Cloudflare yayınları.
İşin kendisi `pisec` ve `docker` komutlarında; panel onları kabuk kullanmadan, argüman
listesiyle çağırıyor.

Flask ile yazıldı, Debian paketleriyle çalışıyor (`python3-flask`, `python3-waitress`);
pip ya da sanal ortam gerekmiyor. Pi 4'te boşta 40 MB civarı bellek kullanıyor.

## Kurulum

```bash
./setup.sh --with-panel       # parola sorar, paneli kullanıcı servisi olarak başlatır
```

Sonradan:

```bash
pisec panel passwd            # parolayı değiştir
pisec panel start|stop|restart
pisec panel                   # durum ve adres
```

Panel `127.0.0.1:8090`'da dinliyor; ağdaki başka bir cihaz doğrudan erişemez. Ayarlar
`~/.config/pisec/panel.json` dosyasında (izinler 600): parola özeti, oturum anahtarı,
`host`, `port`, `cookie_secure`.

## Erişim

**SSH tüneli** (önerilen, ek ayar gerektirmez). Kendi bilgisayarında:

```bash
ssh -L 8090:127.0.0.1:8090 kullanici@pisecbox.local
```

Bağlantı açıkken tarayıcıda `http://localhost:8090`.

**Yerel ağ.** `panel.json` içinde `"host": "0.0.0.0"` yap, ufw'de sadece yerel ağa aç:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8090 proto tcp
pisec panel restart
```

Bağlantı HTTP olduğu için parola ağda açık gider; güvendiğin ağlar dışında kullanma.

### Cloudflare Tunnel ve Access

Paneli internetten açmanın önerilen yolu: Cloudflare Tunnel ile yayınla, önüne
Cloudflare Access koy. Böylece panelin giriş sayfasına ulaşmadan önce Cloudflare
kimliğini doğrular (ör. e-postana gelen tek kullanımlık kod). Gerekenler: ücretsiz bir
Cloudflare hesabı ve Cloudflare'da yönetilen bir alan adı.

1. Cloudflare Zero Trust panelinde **Networks → Tunnels → Create a tunnel**, tür olarak
   Cloudflared. Kurulum adımında gösterilen token'ı kopyala.
2. Pi'de:
   ```bash
   pisec tunnel token        # token'ı yapıştır
   pisec tunnel start
   ```
3. Tünelin **Public hostname** sekmesinde bir adres ekle: `panel.alanadin.com`, servis
   `HTTP`, adres `localhost:8090`.
4. **Access → Applications → Add an application → Self-hosted**. Uygulama adresi
   `panel.alanadin.com`. Politika: **Allow**, kural **Emails** ve kendi e-posta adresin.
5. Pi'de `panel.json` içinde `"cookie_secure": true` yap ve `pisec panel restart`.

Aynı tünele başka adresler de ekleyebilirsin; örneğin `blog.alanadin.com → localhost:8081`
Access olmadan herkese açık bir site olur.

Cloudflare'ın menü adları zaman zaman değişiyor; adımlar aynı kalıyor: tünel oluştur,
token'ı Pi'ye ver, adresi bir porta yönlendir, panelin adresini Access ile koru.

## Sayfalar

| Sayfa | Ne var |
|---|---|
| Genel bakış | Sistem (sıcaklık, bellek, disk), servis durumları, Tor çıkış IP'si, son işler, zamanlanmış görevler, son taramalar |
| Taramalar | `scan`, `recon`, `web`, `lan` başlatma; canlı çıktı, durdurma, geçmiş |
| Sonuçlar | Hedeflere göre çalıştırmalar, `ozet.md`'nin işlenmiş hali, ham dosyalar |
| Zamanlama | `pisec schedule` görevleri: ekleme, silme, hemen çalıştırma |
| Kapsam | İzinli hedef listesi |
| Docker | `~/pisec-apps` altındaki compose uygulamaları ve tüm konteynerler: başlat, durdur, günlük |
| Yayınla | Geçici `trycloudflare.com` adresleri ve kalıcı tünel |
| Sistem | Tor yeni devre, araç güncelleme, ntfy ayarı, araç sürümleri, parola |

Aynı anda en fazla iki iş çalışıyor; Pi'nin belleği ve ağı bundan fazlasını iyi
kaldırmıyor. İş günlükleri `~/.local/state/pisec/jobs` altında.

## Docker uygulamaları

Docker sayfasındaki "Yeni uygulama" bir ad ve bir `compose.yaml` istiyor; dosya
`~/pisec-apps/<ad>/compose.yaml` olarak kaydediliyor, compose projesi `pisec-<ad>`
adıyla çalışıyor. Hazır şablon `./site` klasörünü yayınlayan bir nginx.

Port eşlemeleri `127.0.0.1:` ile başlamak zorunda. Docker kendi iptables kurallarını
ufw'den önce yazıyor; `"8080:80"` gibi bir eşleme ufw kapalı dese de portu bütün ağa
açar. Uygulamayı dışarıya açmak için Yayınla sayfasını ya da kalıcı tüneli kullan.
Konteyner listesinde bu kurala uymayan, tüm arayüzlere açık portlar "dışa açık" diye
işaretleniyor.

Panelin Docker'a erişmesi için kullanıcının `docker` grubunda olması gerekiyor
(`setup.sh --with-docker` ekliyor). Bu grup root'a denk yetki veriyor; paneli ele
geçiren biri Pi'yi de ele geçirmiş olur. Paneli internete açacaksan Access adımını atlama.

## Güvenlik

- Varsayılan olarak sadece `127.0.0.1`.
- Serbest komut satırı yok. Çalıştırılabilen her şey tanımlı: `pisec` alt komutları,
  belirli `docker` ve `docker compose` işlemleri, araç güncellemeleri. Hedef, port ve ad
  gibi girdiler düzenli ifadelerle doğrulanıyor; `-` ile başlayan değerler kabul edilmiyor.
- Parola Werkzeug'un `scrypt` özetiyle saklanıyor. 10 dakikada 5 hatalı denemeden sonra
  giriş kilitleniyor.
- Oturum çerezi `HttpOnly` ve `SameSite=Strict`; Cloudflare üzerinden kullanırken
  `cookie_secure` ile `Secure` de ekleniyor. Bütün POST istekleri CSRF anahtarı istiyor.
- `Content-Security-Policy` sadece panelin kendi dosyalarına izin veriyor; satır içi
  betik ve stil yok.
- Tarama özetleri taranan sitelerden gelen metinler (sayfa başlıkları gibi) içerdiği için
  genel bir Markdown kütüphanesiyle değil, sadece başlık, liste, tablo ve kod destekleyen
  küçük bir dönüştürücüyle işleniyor; her şey kaçışlanıyor. Ham dosyalar `text/plain`
  olarak gönderiliyor.
- Panel geçici `trycloudflare.com` tüneliyle yayınlanamıyor.

## Demo modu

```bash
panel/demo/run.sh            # http://127.0.0.1:8099
```

Paneli örnek verilerle ve girişsiz açar; `panel/demo/bin` altındaki sahte `pisec` ve
`docker` gerçek bir şey çalıştırmaz. Arayüz geliştirmek ve ekran görüntüsü almak için.
Demo modu `127.0.0.1` dışında bir adreste açılmayı reddediyor.
