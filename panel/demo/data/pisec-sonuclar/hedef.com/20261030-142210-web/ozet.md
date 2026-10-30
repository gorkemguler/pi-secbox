# pisec web: hedef.com

- Tarih: 2026-10-30 14:22:10
- Kapsam: listede
- Tor: evet, çıkış IP'si 198.51.100.23
- URL: https://hedef.com

## HTTP başlıkları

- Yanıt: HTTP/2 200
- Eksik güvenlik başlıkları: Content-Security-Policy Permissions-Policy
- Sürüm bilgisi verebilen başlık: `server: nginx/1.24.0`

## TLS (testssl.sh)

- Bulgular: LOW: 2, MEDIUM: 1
- MEDIUM BREACH: potentially VULNERABLE, gzip HTTP compression detected

## nuclei

2 bulgu:

- [http-missing-security-headers:content-security-policy] [http] [info] https://hedef.com
- [git-config] [http] [medium] https://hedef.com/.git/config

Tor modunda sadece HTTP şablonları çalıştı ve OAST kapalıydı. Tor çıkışlarını
engelleyen sitelerde "bulgu yok" hedefin temiz olduğu anlamına gelmiyor.
