#!/usr/bin/env bats

load helpers

setup() {
    setup_mocks
}

# --- Genel ---------------------------------------------------------------------

@test "--help kullanım bilgisini gösterir" {
    run "$PISEC" --help
    [ "$status" -eq 0 ]
    [[ $output == *"Kullanım: pisec"* ]]
}

@test "bilinmeyen komut ve seçenek hata verir" {
    run "$PISEC" foo </dev/null
    [ "$status" -eq 1 ]
    [[ $output == *"Bilinmeyen komut: foo"* ]]

    run "$PISEC" scan 192.168.1.10 --hizli </dev/null
    [ "$status" -eq 1 ]
    [[ $output == *"Bilinmeyen seçenek: --hizli"* ]]
}

@test "argümansız ve terminal yokken menü yerine kullanımı gösterir" {
    run "$PISEC" </dev/null
    [ "$status" -eq 1 ]
    [[ $output == *"Kullanım: pisec"* ]]
}

@test "geçersiz port listesi ve önem seviyesi reddedilir" {
    run "$PISEC" scan 192.168.1.10 -y -p '22;id'
    [ "$status" -eq 1 ]
    run "$PISEC" web hedef.com -y -s 'high;id'
    [ "$status" -eq 1 ]
    not_called nmap
    not_called nuclei
}

# --- Kapsam --------------------------------------------------------------------

@test "scope add, list ve rm" {
    run "$PISEC" scope add Hedef.com 10.0.0.0/24
    [ "$status" -eq 0 ]

    run "$PISEC" scope
    [[ $output == *"hedef.com"* ]]
    [[ $output == *"10.0.0.0/24"* ]]

    run "$PISEC" scope add hedef.com
    [[ $output == *"zaten listede"* ]]

    run "$PISEC" scope rm hedef.com
    [ "$status" -eq 0 ]
    run "$PISEC" scope
    [[ $output != *"hedef.com"* ]]
    [[ $output == *"10.0.0.0/24"* ]]
}

@test "scope add geçersiz hedefi reddeder" {
    run "$PISEC" scope add 'hedef.com;id'
    [ "$status" -eq 1 ]
    [[ $output == *"Geçersiz hedef"* ]]
}

@test "kapsam dışı hedef terminal yokken reddedilir" {
    "$PISEC" scope add hedef.com
    run "$PISEC" scan kotuhedef.com </dev/null
    [ "$status" -eq 1 ]
    [[ $output == *"kapsam listesinde yok"* ]]
    not_called nmap
}

@test "alan adı alt alan adlarını kapsar, benzer isimleri kapsamaz" {
    "$PISEC" scope add hedef.com
    run "$PISEC" scan api.hedef.com </dev/null
    [ "$status" -eq 0 ]
    run "$PISEC" scan kotuhedef.com </dev/null
    [ "$status" -eq 1 ]
}

@test "CIDR kapsamı içindeki adres ve alt ağ kabul edilir, dışındakiler edilmez" {
    "$PISEC" scope add 192.168.1.0/24
    run "$PISEC" scan 192.168.1.50 </dev/null
    [ "$status" -eq 0 ]
    run "$PISEC" scan 192.168.1.128/25 </dev/null
    [ "$status" -eq 0 ]
    run "$PISEC" scan 192.168.2.1 </dev/null
    [ "$status" -eq 1 ]
    run "$PISEC" scan 192.168.0.0/16 </dev/null
    [ "$status" -eq 1 ]
}

@test "-y kapsam dışı hedefte devam eder ve bunu özete yazar" {
    run "$PISEC" scan 203.0.113.5 -y </dev/null
    [ "$status" -eq 0 ]
    [[ $(latest_summary) == *"Kapsam: listede değil, -y ile devam edildi"* ]]
}

# --- scan ----------------------------------------------------------------------

@test "yerel tarama nmap'i doğrudan, servis tespitiyle çalıştırır" {
    run "$PISEC" scan 192.168.1.10 -y
    [ "$status" -eq 0 ]
    calls nmap | grep -q -- '-sV -T4 --open --top-ports 1000 -oA .*/nmap 192.168.1.10$'
    not_called proxychains4

    summary=$(latest_summary)
    [[ $summary == *"| 192.168.1.10 | 22/tcp | ssh | OpenSSH 9.2p1 |"* ]]
    [[ $summary == *"| 192.168.1.10 | 80/tcp | http | nginx |"* ]]
    [[ $summary != *"443/tcp"* ]]
    grep -q '^nmap ' "$(latest_run)/komutlar.txt"
}

@test "-p ve -- ile verilen seçenekler nmap'e geçer" {
    run "$PISEC" scan 192.168.1.10 -y -p 22,80 -- -sC
    [ "$status" -eq 0 ]
    calls nmap | grep -q -- '-p 22,80 -sC -oA'
}

@test "Tor ile tarama adresi Tor'dan çözer ve proxychains ile connect taraması yapar" {
    run "$PISEC" scan hedef.com --tor -y
    [ "$status" -eq 0 ]
    calls tor-resolve | grep -q 'hedef.com 127.0.0.1:9050'
    calls proxychains4 | grep -q -- '-q -f .*/proxychains-fast.conf nmap -sT -Pn -n --open --top-ports 100 -oA .*/nmap 198.51.100.7$'
    grep -q '^tcp_read_time_out 15000$' "$MOCK_DIR/proxychains.conf"
    grep -q '^socks5 127.0.0.1 9050 pisec[0-9]* x$' "$MOCK_DIR/proxychains.conf"
    grep -q '^proxy_dns$' "$MOCK_DIR/proxychains.conf"

    summary=$(latest_summary)
    [[ $summary == *"Tor: evet, çıkış IP'si 203.0.113.9"* ]]
    [[ $summary == *"Adres: 198.51.100.7 (Tor üzerinden çözüldü)"* ]]
}

@test "Tor ile --sv servis tespitini ekler" {
    run "$PISEC" scan hedef.com --tor --sv -y
    [ "$status" -eq 0 ]
    calls nmap | grep -q -- '-sT -Pn -n --open -sV'
}

@test "Tor ile özel adres, ağ aralığı ve ham soket seçenekleri reddedilir" {
    run "$PISEC" scan 192.168.1.10 --tor -y
    [ "$status" -eq 1 ]
    [[ $output == *"özel bir adres"* ]]

    run "$PISEC" scan 203.0.113.0/24 --tor -y
    [ "$status" -eq 1 ]
    [[ $output == *"ağ aralığı taranmaz"* ]]

    for opt in -sS -sU -O -PE; do
        run "$PISEC" scan hedef.com --tor -y -- "$opt"
        [ "$status" -eq 1 ]
        [[ $output == *"$opt Tor üzerinden çalışmaz"* ]]
    done
    not_called nmap
}

@test "Tor ile özel adrese çözülen alan adı reddedilir" {
    export MOCK_RESOLVE=10.1.2.3
    run "$PISEC" scan ic.hedef.com --tor -y
    [ "$status" -eq 1 ]
    [[ $output == *"özel bir adrese (10.1.2.3)"* ]]
    not_called nmap
}

# --- recon ---------------------------------------------------------------------

@test "recon subfinder, dnsx ve httpx'i çalıştırır" {
    run "$PISEC" recon hedef.com -y
    [ "$status" -eq 0 ]
    calls subfinder | grep -q -- '-d hedef.com'
    calls dnsx >/dev/null
    calls httpx >/dev/null

    summary=$(latest_summary)
    [[ $summary == *"Alt alan adı: 2"* ]]
    [[ $summary == *"DNS kaydı olan: 2"* ]]
    [[ $summary == *"Canlı web servisi: 1"* ]]
}

@test "recon Tor ile dnsx'i atlar, diğer araçlara proxy verir" {
    run "$PISEC" recon hedef.com --tor -y
    [ "$status" -eq 0 ]
    not_called dnsx
    calls subfinder | grep -q -- '-proxy socks5://pisec[0-9]*:x@127.0.0.1:9050 -es crtsh'
    calls httpx | grep -q -- '-proxy socks5://pisec[0-9]*:x@127.0.0.1:9050'
}

@test "recon önceki çalıştırmaya göre değişen alt alan adlarını gösterir" {
    "$PISEC" recon hedef.com -y </dev/null
    export MOCK_SUBS="www.hedef.com yeni.hedef.com"
    run "$PISEC" recon hedef.com -y </dev/null
    [ "$status" -eq 0 ]

    summary=$(latest_summary)
    [[ $summary == *"Yeni alt alan adları:"*"- yeni.hedef.com"* ]]
    [[ $summary == *"Artık görünmeyenler:"*"- api.hedef.com"* ]]
}

@test "recon IP adresini reddeder" {
    run "$PISEC" recon 203.0.113.5 -y
    [ "$status" -eq 1 ]
    [[ $output == *"Geçersiz alan adı"* ]]
}

# --- web -----------------------------------------------------------------------

@test "web başlıkları son yanıttan değerlendirir, testssl ve nuclei sonuçlarını özetler" {
    run "$PISEC" web hedef.com -y
    [ "$status" -eq 0 ]
    not_called proxychains4
    calls nuclei | grep -q -- '-u https://hedef.com -duc'

    summary=$(latest_summary)
    [[ $summary == *"Yanıt: HTTP/2 200"* ]]
    [[ $summary == *"Eksik güvenlik başlıkları: Strict-Transport-Security Content-Security-Policy X-Frame-Options Referrer-Policy Permissions-Policy"* ]]
    [[ $summary == *'`server: nginx/1.24.0`'* ]]
    [[ $summary == *"Bulgular: HIGH: 1, MEDIUM: 1"* ]]
    [[ $summary == *"- HIGH cert_expiration: expires in 3 days"* ]]
    [[ $summary == *"[git-config] [http] [medium]"* ]]
}

@test "web Tor ile testssl'e Tor'dan çözülen adresi verir, nuclei'yi HTTP şablonlarıyla sınırlar" {
    run "$PISEC" web https://hedef.com --tor -y
    [ "$status" -eq 0 ]
    calls curl | grep -q -- '-k -L --max-time 90 .*--proxy socks5h://pisec[0-9]*:x@127.0.0.1:9050 https://hedef.com$'
    calls proxychains4 | grep -q -- '-q -f .*/proxychains-slow.conf testssl .* --ip 198.51.100.7 --nodns none https://hedef.com$'
    grep -q '^tcp_read_time_out 60000$' "$MOCK_DIR/proxychains.conf"
    calls nuclei | grep -q -- '-proxy socks5://pisec[0-9]*:x@127.0.0.1:9050 -pt http -ni'
    [[ $(latest_summary) == *"Tor modunda sadece HTTP şablonları çalıştı"* ]]
}

@test "web http adresinde testssl'i ve HSTS kontrolünü atlar" {
    run "$PISEC" web http://hedef.com -y
    [ "$status" -eq 0 ]
    not_called testssl
    [[ $(latest_summary) != *"Strict-Transport-Security"* ]]
}

@test "web --no-nuclei ve --no-tls ilgili adımları atlar" {
    run "$PISEC" web hedef.com -y --no-nuclei --no-tls
    [ "$status" -eq 0 ]
    not_called nuclei
    not_called testssl
    calls curl >/dev/null
}

# --- lan -----------------------------------------------------------------------

@test "lan bağlı olunan ağı bulur ve sudo ile ARP taraması yapar" {
    "$PISEC" scope add 192.168.1.0/24
    run "$PISEC" lan </dev/null
    [ "$status" -eq 0 ]
    calls sudo | grep -q 'nmap -sn -oA .*/nmap 192.168.1.0/24$'

    summary=$(latest_summary)
    [[ $summary == *"| 192.168.1.1 | router.lan | AA:BB:CC:DD:EE:01 | Ubiquiti Networks |"* ]]
    [[ $summary == *"| 192.168.1.23 |  | AA:BB:CC:DD:EE:02 | Apple |"* ]]
    [[ $summary == *"3 cihaz bulundu."* ]]
}

@test "lan Tor ile çalışmaz" {
    run "$PISEC" lan --tor </dev/null
    [ "$status" -eq 1 ]
    not_called nmap
}

# --- tor, results --------------------------------------------------------------

@test "tor status çıkış IP'sini gösterir" {
    run "$PISEC" tor status
    [ "$status" -eq 0 ]
    [[ $output == *"Çıkış IP'si: 203.0.113.9 (Tor: true)"* ]]
}

@test "tor new çerez okunamazsa grup üyeliğini anlatır" {
    export PISEC_TOR_COOKIE=$MOCK_DIR/olmayan-cerez
    run "$PISEC" tor new
    [ "$status" -eq 1 ]
    [[ $output == *"debian-tor"* ]]
}

@test "results kayıtlı hedefleri listeler ve son özeti gösterir" {
    run "$PISEC" results
    [[ $output == *"Henüz kayıtlı sonuç yok"* ]]

    "$PISEC" scan 192.168.1.10 -y </dev/null
    run "$PISEC" results
    [[ $output == *"192.168.1.10  (1 çalıştırma, son: "*"-scan)"* ]]

    run "$PISEC" results 192.168.1.10
    [ "$status" -eq 0 ]
    [[ $output == *"# pisec scan: 192.168.1.10"* ]]
}

# --- Değişiklik takibi ve bildirim ---------------------------------------------

@test "scan önceki taramaya göre yeni açılan portları gösterir" {
    "$PISEC" scan 203.0.113.5 -y </dev/null
    export MOCK_PORTS="22/open/tcp//ssh///, 80/open/tcp//http///, 8080/open/tcp//http-proxy///"
    run "$PISEC" scan 203.0.113.5 -y </dev/null
    [ "$status" -eq 0 ]
    summary=$(latest_summary)
    [[ $summary == *"Yeni açılan portlar:"*"- 8080/tcp"* ]]
    [[ $summary != *"Artık açık görünmeyenler"* ]]
}

@test "notify set adresi kaydeder, tarama bitince ntfy'ye bildirim gider" {
    run "$PISEC" notify set https://ntfy.sh/pisec-deneme
    [ "$status" -eq 0 ]
    grep -qx 'NTFY_URL=https://ntfy.sh/pisec-deneme' "$HOME/.config/pisec/config"
    [ "$(stat -c %a "$HOME/.config/pisec/config" 2>/dev/null || stat -f %Lp "$HOME/.config/pisec/config")" = 600 ]

    "$PISEC" scan 192.168.1.10 -y </dev/null
    calls curl | grep -q -- '-d .*"topic": *"pisec-deneme".* https://ntfy.sh$'
    calls curl | grep -q '2 açık port'
}

@test "notify geçersiz adresi reddeder, off kapatır" {
    run "$PISEC" notify set 'https://ntfy.sh/a b'
    [ "$status" -eq 1 ]
    "$PISEC" notify set https://ntfy.sh/pisec-deneme
    "$PISEC" notify off
    run "$PISEC" notify
    [[ $output == *"Bildirimler kapalı"* ]]
}

# --- schedule ------------------------------------------------------------------

@test "schedule add systemd zamanlayıcısı ve servisi oluşturur" {
    "$PISEC" scope add hedef.com
    run "$PISEC" schedule add "Mon *-*-* 03:00" scan hedef.com --tor -p 22,443
    [ "$status" -eq 0 ]
    unit=$HOME/.config/systemd/user/pisec-job-scan-hedef.com
    grep -qx 'OnCalendar=Mon \*-\*-\* 03:00' "$unit.timer"
    grep -qx 'Persistent=true' "$unit.timer"
    grep -q '^ExecStart=/.*/pisec scan hedef.com --tor -p 22,443$' "$unit.service"
    [ -z "$(grep -- ' -y' "$unit.service" || true)" ]
    calls systemctl | grep -q 'enable --now pisec-job-scan-hedef.com.timer'
}

@test "schedule add kapsam dışı hedefi, bozuk zamanı ve var olan adı reddeder" {
    run "$PISEC" schedule add daily recon hedef.com
    [ "$status" -eq 1 ]
    [[ $output == *"kapsam listesinde olmalı"* ]]

    "$PISEC" scope add hedef.com
    run "$PISEC" schedule add "bozuk zaman" recon hedef.com
    [ "$status" -eq 1 ]
    [[ $output == *"Geçersiz zaman"* ]]

    "$PISEC" schedule add daily recon hedef.com
    run "$PISEC" schedule add weekly recon hedef.com
    [ "$status" -eq 1 ]
    [[ $output == *"zaten var"* ]]
    run "$PISEC" schedule add weekly recon hedef.com --name haftalik
    [ "$status" -eq 0 ]
}

@test "schedule list JSON verir, rm görevi siler" {
    "$PISEC" scope add 192.168.1.0/24
    "$PISEC" schedule add hourly lan 192.168.1.0/24
    run "$PISEC" schedule list --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].name' <<<"$output")" = "lan-192.168.1.0-24" ]
    [ "$(jq -r '.[0].command' <<<"$output")" = "lan 192.168.1.0/24" ]

    run "$PISEC" schedule rm lan-192.168.1.0-24
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.config/systemd/user/pisec-job-lan-192.168.1.0-24.timer" ]
    run "$PISEC" schedule list --json
    [ "$output" = "[]" ]
}

# --- publish, tunnel -----------------------------------------------------------

@test "publish adres verir, listeler ve kapatır" {
    run "$PISEC" publish 8081 -y
    [ "$status" -eq 0 ]
    [[ $output == *"Yayında: https://deneme-ornek-adres.trycloudflare.com -> 127.0.0.1:8081"* ]]
    calls systemd-run | grep -q -- '--unit pisec-publish-8081 .*cloudflared tunnel --no-autoupdate .*--url http://127.0.0.1:8081'

    run "$PISEC" publish list --json
    [ "$(jq -r '.[0].url' <<<"$output")" = "https://deneme-ornek-adres.trycloudflare.com" ]

    run "$PISEC" publish stop 8081
    [ "$status" -eq 0 ]
    run "$PISEC" publish list
    [[ $output == *"Yayında port yok"* ]]
}

@test "publish onay olmadan ve panel portunda çalışmaz" {
    run "$PISEC" publish 8081 </dev/null
    [ "$status" -eq 1 ]
    [[ $output == *"-y ver"* ]]
    run "$PISEC" publish 8090 -y
    [ "$status" -eq 1 ]
    [[ $output == *"Panel geçici tünelle yayınlanmaz"* ]]
    not_called systemd-run
}

@test "tunnel token stdin'den okunur ve sadece kullanıcının okuyabileceği dosyaya yazılır" {
    token=eyJhIjoiMTIzNDU2Nzg5MCIsInQiOiJhYmNkZWYiLCJzIjoiWlhoaGJYQnNaUT09In0
    run "$PISEC" tunnel token <<<"$token"
    [ "$status" -eq 0 ]
    grep -qx "TUNNEL_TOKEN=$token" "$HOME/.config/pisec/cloudflared.env"
    [ "$(stat -c %a "$HOME/.config/pisec/cloudflared.env" 2>/dev/null || stat -f %Lp "$HOME/.config/pisec/cloudflared.env")" = 600 ]

    run "$PISEC" tunnel token <<<"kisa"
    [ "$status" -eq 1 ]
}

@test "scope check URL'den alan adını çıkarır" {
    "$PISEC" scope add hedef.com
    run "$PISEC" scope check https://api.hedef.com/giris
    [ "$status" -eq 0 ]
    run "$PISEC" scope check https://baska.com
    [ "$status" -eq 1 ]
}
