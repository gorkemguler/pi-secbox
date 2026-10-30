# Katkı

Hata bildirimi, öneri ve pull request'ler açık. Büyük bir değişiklikten önce issue açıp
konuşmak iki tarafın da zamanını korur.

## Depo düzeni

```
setup.sh, uninstall.sh   kurulum ve kaldırma
pisec                    komut satırı aracı (bash)
cheatsheet.md            ~/pisecbox-cheatsheet.md olarak kopyalanan komut notları
panel/app.py             web paneli (Flask)
panel/templates, static  panel arayüzü; dış CDN yok
panel/demo               sahte araçlar ve örnek verilerle demo modu
panel/tests              panel testleri (unittest)
test/                    bats testleri ve sahte araçlar (test/mock)
docs/                    ayrıntılı dokümanlar, banner, ekran görüntüleri
```

## Testler

Testler gerçek araç çalıştırmıyor ve ağa çıkmıyor; Linux'ta ya da Pi'de çalıştır.
macOS'un kendi bash'i (3.2) betikler için fazla eski.

```bash
sudo apt install bats shellcheck python3-flask python3-waitress
bats test/
python3 -m unittest discover -s panel/tests
shellcheck setup.sh uninstall.sh pisec test/mock test/helpers.bash
```

Yeni bir `pisec` özelliği için `test/pisec.bats`'a test ekle. Araç çağrıları
`test/mock` tarafından `$MOCK_LOG`'a yazılıyor; testler hangi aracın hangi argümanlarla
çağrıldığına bakıyor. Panel için `panel/tests/test_panel.py`.

Arayüzde değişiklik yaptıysan `panel/demo/run.sh` ile bak; ekran görüntülerini
güncellemek gerekiyorsa PR'da belirt.

## Yazım

- Bash: `set -euo pipefail`, shellcheck uyarısız. Yardımcı fonksiyonlar `log`, `warn`,
  `die`.
- Kullanıcıya görünen metinler ve yorumlar Türkçe, sade. Neyin neden yapıldığını yaz;
  kodun ne yaptığını tekrar etme.
- Panelde yeni bir işlem eklerken komutu kabuk olmadan, argüman listesiyle çağır ve
  girdiyi düzenli ifadeyle doğrula. Serbest komut çalıştıran bir özellik kabul edilmiyor.
- Kullanıcı verisini silen her şey onay ister ya da `--purge` gibi açık bir seçeneğe
  bağlıdır.
