#!/usr/bin/env bash
#
# pi-secbox kurulum betiği
# Raspberry Pi OS Lite üzerine ağ keşfi / denetim araçlarını, Tor + proxychains'i,
# pisec komutunu ve temel sıkılaştırmayı (ufw, fail2ban) kurar. İsteğe bağlı olarak
# web panelini, Docker'ı ve cloudflared'ı ekler. Birden fazla kez çalıştırılabilir.
#
set -euo pipefail

PDTM_TOOLS="nuclei,subfinder,httpx,naabu,dnsx"
PDTM_BIN="$HOME/.pdtm/go/bin"
TEMPLATES_DIR="$HOME/nuclei-templates"
NUCLEI_CONF="$HOME/.config/nuclei/config.yaml"
TESTSSL_DIR="/opt/testssl.sh"
TESTSSL_BRANCH="3.2"
PROXYCHAINS_CONF="/etc/proxychains4.conf"
CHEATSHEET="$HOME/pisecbox-cheatsheet.md"
PANEL_DIR="/usr/local/lib/pisec-panel"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CLOUDFLARE_KEY="/usr/share/keyrings/cloudflare-public-v2.gpg"
CLOUDFLARE_LIST="/etc/apt/sources.list.d/cloudflared.list"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_UPGRADE=1
DO_FIREWALL=1
WITH_PANEL=0
WITH_DOCKER=0
WITH_CLOUDFLARED=0
RELOGIN=0
TMP_DIR=""
SUDO_KEEPALIVE_PID=""

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -n "$SUDO_KEEPALIVE_PID" ]; then kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; fi
    if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

usage() {
    cat <<EOF
Kullanım: ./setup.sh [seçenekler]

  --no-upgrade        apt full-upgrade adımını atla
  --no-firewall       ufw ayarlarına dokunma
  --with-panel        web panelini kur (sadece 127.0.0.1'de dinler)
  --with-docker       Docker ve docker compose kur
  --with-cloudflared  Cloudflare'ın apt deposundan cloudflared kur
  --all               panel, Docker ve cloudflared'ın üçü birden
  -h, --help          bu yardımı göster
EOF
}

apt_get() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-upgrade)  DO_UPGRADE=0 ;;
        --no-firewall) DO_FIREWALL=0 ;;
        --with-panel)  WITH_PANEL=1 ;;
        --with-docker) WITH_DOCKER=1 ;;
        --with-cloudflared) WITH_CLOUDFLARED=1 ;;
        --all)         WITH_PANEL=1; WITH_DOCKER=1; WITH_CLOUDFLARED=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "Bilinmeyen seçenek: $1" ;;
    esac
    shift
done

# Araçlar $HOME altına kuruluyor; sudo ile çalıştırılırsa her şey /root'a gider.
[ "$(id -u)" -ne 0 ] || die "Betiği root olarak değil, kendi kullanıcınla çalıştır. Gereken yerde sudo zaten çağrılıyor."
command -v apt-get >/dev/null || die "apt-get bulunamadı. Bu betik Debian tabanlı sistemler için."

case "$(uname -m)" in
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv6l) ARCH=arm ;;
    x86_64)        ARCH=amd64 ;;
    *)             die "Desteklenmeyen mimari: $(uname -m)" ;;
esac

sudo -v
# apt full-upgrade yavaş bir kartta sudo'nun 15 dakikalık süresini aşabiliyor.
while true; do sudo -n true; sleep 50; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!

# --- Paketler -----------------------------------------------------------------

if [ "$WITH_CLOUDFLARED" -eq 1 ] && [ ! -f "$CLOUDFLARE_LIST" ]; then
    log "Cloudflare apt deposu ekleniyor"
    sudo install -d -m 755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee "$CLOUDFLARE_KEY" >/dev/null
    echo "deb [signed-by=$CLOUDFLARE_KEY] https://pkg.cloudflare.com/cloudflared any main" \
        | sudo tee "$CLOUDFLARE_LIST" >/dev/null
fi

log "Paket listesi güncelleniyor"
apt_get update
if [ "$DO_UPGRADE" -eq 1 ]; then
    log "Sistem güncelleniyor (atlamak için --no-upgrade)"
    apt_get full-upgrade
fi

PACKAGES=(
    nmap tcpdump tshark whois dnsutils macchanger
    tor torsocks proxychains4
    ufw fail2ban python3-systemd
    tmux git curl wget jq unzip
    bsdextrautils procps python3
)

# Masaüstü sürümünde rpi-connect kurulu olabilir, lite paketi onunla çakışıyor.
if dpkg -s rpi-connect >/dev/null 2>&1; then
    :
elif apt-cache show rpi-connect-lite >/dev/null 2>&1; then
    PACKAGES+=(rpi-connect-lite)
else
    warn "rpi-connect-lite depoda yok (Raspberry Pi OS değil mi?), atlanıyor."
fi

if [ "$WITH_PANEL" -eq 1 ]; then PACKAGES+=(python3-flask python3-waitress); fi
if [ "$WITH_CLOUDFLARED" -eq 1 ]; then PACKAGES+=(cloudflared); fi
if [ "$WITH_DOCKER" -eq 1 ]; then
    PACKAGES+=(docker.io)
    # Debian 13'te compose v2 "docker-compose", Ubuntu'da "docker-compose-v2" paketinde.
    if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
        PACKAGES+=(docker-compose-v2)
    elif apt-cache show docker-compose >/dev/null 2>&1; then
        PACKAGES+=(docker-compose)
    fi
fi

log "Paketler kuruluyor"
apt_get install "${PACKAGES[@]}"

# Zamanlanmış taramalar, panel ve Pi Connect kullanıcı servisi olarak çalışıyor;
# linger açık olmazsa oturum kapanınca hepsi duruyor.
sudo loginctl enable-linger "$(id -un)"

# --- PATH ---------------------------------------------------------------------

if ! grep -qF '# pi-secbox' "$HOME/.bashrc" 2>/dev/null; then
    log ".bashrc dosyasına PATH ekleniyor"
    cat >> "$HOME/.bashrc" <<'EOF'

# pi-secbox
export PATH="$HOME/.pdtm/go/bin:$PATH"
EOF
fi
export PATH="$PDTM_BIN:$PATH"

# --- ProjectDiscovery araçları ------------------------------------------------
# Go derleyicisi kurmak yerine pdtm'nin hazır binary'sini indiriyoruz. Pi'de
# derleme hem uzun sürüyor hem de 512 MB RAM'li modellerde bellek yetmiyor.

if ! command -v pdtm >/dev/null; then
    log "pdtm indiriliyor"
    tag=$(curl -fsSL https://api.github.com/repos/projectdiscovery/pdtm/releases/latest | jq -r .tag_name)
    if [ -z "$tag" ] || [ "$tag" = "null" ]; then die "pdtm sürüm bilgisi alınamadı."; fi
    ver=${tag#v}
    zip="pdtm_${ver}_linux_${ARCH}.zip"
    TMP_DIR=$(mktemp -d)
    base="https://github.com/projectdiscovery/pdtm/releases/download/$tag"
    curl -fsSL -o "$TMP_DIR/$zip" "$base/$zip"
    curl -fsSL -o "$TMP_DIR/checksums.txt" "$base/pdtm_${ver}_checksums.txt"
    (cd "$TMP_DIR" && grep "  $zip\$" checksums.txt | sha256sum -c --quiet -) \
        || die "pdtm arşivinin SHA256 doğrulaması başarısız."
    unzip -o -q "$TMP_DIR/$zip" pdtm -d "$TMP_DIR"
    mkdir -p "$PDTM_BIN"
    install -m 755 "$TMP_DIR/pdtm" "$PDTM_BIN/pdtm"
fi

log "nuclei, subfinder, httpx, naabu ve dnsx kuruluyor / güncelleniyor"
pdtm -duc -dc -nc -i "$PDTM_TOOLS"
pdtm -duc -dc -nc -u "$PDTM_TOOLS"

has_templates() { find "$TEMPLATES_DIR" -name '*.yaml' -print -quit 2>/dev/null | grep -q .; }

# nuclei şablon arşivini (~20 MB) 30 saniyelik sabit bir süre sınırıyla indiriyor.
# Yavaş Wi-Fi'de bu yetmiyor ve nuclei hata vermeden boş bir dizin bırakıyor.
# O durumda depoyu git ile çekip nuclei'nin açılıştaki güncelleme denemesini
# kapatıyoruz, yoksa her çalıştırmada yarım dakika bekliyor.
if [ -d "$TEMPLATES_DIR/.git" ]; then
    log "Nuclei şablonları güncelleniyor (git)"
    git -C "$TEMPLATES_DIR" pull -q --ff-only || warn "Şablonlar güncellenemedi."
else
    log "Nuclei şablonları indiriliyor"
    nuclei -update-templates >/dev/null 2>&1 || true
    if ! has_templates; then
        warn "nuclei şablonları indiremedi (bağlantı yavaş olabilir), git ile çekiliyor."
        if [ -d "$TEMPLATES_DIR" ]; then
            rmdir "$TEMPLATES_DIR" 2>/dev/null || mv "$TEMPLATES_DIR" "$TEMPLATES_DIR.$(date +%s).bak"
        fi
        git clone -q --depth 1 https://github.com/projectdiscovery/nuclei-templates.git "$TEMPLATES_DIR"
        mkdir -p "$(dirname "$NUCLEI_CONF")"
        if grep -q '^#\?disable-update-check:' "$NUCLEI_CONF" 2>/dev/null; then
            sed -i 's/^#\?disable-update-check:.*/disable-update-check: true/' "$NUCLEI_CONF"
        else
            echo 'disable-update-check: true' >> "$NUCLEI_CONF"
        fi
    fi
fi
has_templates || warn "nuclei şablonları kurulamadı. 'nuclei -ut -v' çıktısına bak."

# --- testssl.sh ---------------------------------------------------------------

if [ -d "$TESTSSL_DIR/.git" ]; then
    log "testssl.sh güncelleniyor"
    sudo git -C "$TESTSSL_DIR" pull -q --ff-only || warn "testssl.sh güncellenemedi."
else
    log "testssl.sh kuruluyor ($TESTSSL_BRANCH dalı)"
    sudo git clone -q --depth 1 --branch "$TESTSSL_BRANCH" \
        https://github.com/testssl/testssl.sh.git "$TESTSSL_DIR"
fi
sudo ln -sf "$TESTSSL_DIR/testssl.sh" /usr/local/bin/testssl

# --- Tor ve proxychains -------------------------------------------------------

log "Tor açılıyor, proxychains4 ayarlanıyor"
sudo systemctl enable --now tor

[ -f "$PROXYCHAINS_CONF.orig" ] || sudo cp "$PROXYCHAINS_CONF" "$PROXYCHAINS_CONF.orig"
# proxy_dns satırı birebir eşleşmeli. Eski sürüm "^#proxy_dns" ile proxy_dns_daemon
# satırını da açıyordu; daemon çalışmadığında proxychains sonsuza kadar bekliyor.
sudo sed -i -E \
    -e 's/^strict_chain/#strict_chain/' \
    -e 's/^#[[:space:]]*dynamic_chain$/dynamic_chain/' \
    -e 's/^#[[:space:]]*proxy_dns$/proxy_dns/' \
    -e 's/^(proxy_dns_(old|daemon))/#\1/' \
    -e 's/^socks4[[:space:]]+127\.0\.0\.1[[:space:]]+9050$/socks5 127.0.0.1 9050/' \
    "$PROXYCHAINS_CONF"

# "pisec tor new" Tor'un kontrol soketini (/run/tor/control) kullanıyor. Debian
# paketi soketi ve çerez dosyasını debian-tor grubuna açıyor.
if ! id -nG "$(id -un)" | tr ' ' '\n' | grep -x debian-tor >/dev/null; then
    sudo usermod -aG debian-tor "$(id -un)"
    RELOGIN=1
fi

# --- Güvenlik duvarı ve fail2ban ----------------------------------------------

if [ "$DO_FIREWALL" -eq 1 ]; then
    log "ufw ayarlanıyor (gelen bağlantılar kapalı, SSH açık)"
    ssh_ports=$(sudo sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true)
    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null
    for port in ${ssh_ports:-22}; do
        sudo ufw limit "$port/tcp" comment 'SSH' >/dev/null
    done
    sudo ufw --force enable >/dev/null
    sudo ufw status verbose
else
    warn "--no-firewall verildi, ufw ayarlarına dokunulmadı."
fi

# Debian 12'de /var/log/auth.log yok; sshd jail'i journald'dan okumazsa fail2ban
# açılmıyor. Debian 13 paketi bunu zaten yapıyor, burada iki sürüm için de yazıyoruz.
log "fail2ban sshd jail'i ayarlanıyor"
sudo tee /etc/fail2ban/jail.d/pisecbox.local >/dev/null <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
sudo systemctl enable fail2ban >/dev/null 2>&1
sudo systemctl restart fail2ban

# --- pisec ve komut notları ---------------------------------------------------

log "pisec kuruluyor"
if [ -f "$SCRIPT_DIR/pisec" ]; then
    sudo install -m 755 "$SCRIPT_DIR/pisec" /usr/local/bin/pisec
else
    warn "pisec bulunamadı, kurulmadı."
fi

# --- İsteğe bağlı: Docker ve web paneli -----------------------------------------

if [ "$WITH_DOCKER" -eq 1 ]; then
    log "Docker açılıyor"
    sudo systemctl enable --now docker
    # docker grubu root'a denk yetki veriyor; panel konteynerleri bu yetkiyle yönetiyor.
    if ! id -nG "$(id -un)" | tr ' ' '\n' | grep -x docker >/dev/null; then
        sudo usermod -aG docker "$(id -un)"
        RELOGIN=1
    fi
fi

if [ "$WITH_PANEL" -eq 1 ]; then
    log "Web paneli kuruluyor ($PANEL_DIR)"
    sudo install -d -m 755 "$PANEL_DIR"
    sudo cp -R "$SCRIPT_DIR/panel/app.py" "$SCRIPT_DIR/panel/templates" "$SCRIPT_DIR/panel/static" "$PANEL_DIR/"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/pisec-panel.service" <<EOF
# setup.sh --with-panel ile oluşturuldu
[Unit]
Description=pisec web paneli

[Service]
Environment=PATH=%h/.pdtm/go/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/python3 $PANEL_DIR/app.py serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    if [ ! -f "$HOME/.config/pisec/panel.json" ]; then
        if [ -t 0 ]; then
            python3 "$PANEL_DIR/app.py" passwd
        else
            warn "Panel parolası belirlenmedi. Sonra: pisec panel passwd && pisec panel start"
        fi
    fi
    if [ -f "$HOME/.config/pisec/panel.json" ]; then
        systemctl --user enable pisec-panel.service >/dev/null 2>&1
        systemctl --user restart pisec-panel.service
    fi
fi

if [ -f "$SCRIPT_DIR/cheatsheet.md" ]; then
    install -m 644 "$SCRIPT_DIR/cheatsheet.md" "$CHEATSHEET"
else
    warn "cheatsheet.md bulunamadı, komut notları kopyalanmadı."
fi

# --- Kontrol ------------------------------------------------------------------

log "Kurulan araçlar"
missing=0
tools=(nmap tshark tor proxychains4 pdtm nuclei subfinder httpx naabu dnsx testssl pisec)
if [ "$WITH_DOCKER" -eq 1 ]; then tools+=(docker); fi
if [ "$WITH_CLOUDFLARED" -eq 1 ]; then tools+=(cloudflared); fi
for t in "${tools[@]}"; do
    if command -v "$t" >/dev/null; then
        printf '    %-12s tamam\n' "$t"
    else
        printf '    %-12s YOK\n' "$t"
        missing=1
    fi
done

log "Tor bağlantısı deneniyor (ilk açılışta bir dakikayı bulabilir)"
tor_ok=0
for _ in $(seq 1 12); do
    if curl -fsS --max-time 15 --socks5-hostname 127.0.0.1:9050 \
            https://check.torproject.org/api/ip 2>/dev/null | grep -q '"IsTor":true'; then
        tor_ok=1
        break
    fi
    sleep 5
done
if [ "$tor_ok" -eq 1 ]; then
    echo "    Tor çalışıyor."
else
    warn "Tor henüz bağlanamadı. 'journalctl -u tor@default' çıktısına bak."
fi

echo
if [ "$RELOGIN" -eq 1 ]; then
    echo "Bitti. Yeni grup üyelikleri (debian-tor, docker) için Pi'yi yeniden başlat:"
    echo "  sudo reboot"
    echo "Yeniden başlatmadan sadece yeni oturumlar görür; panel gibi arka plan servisleri görmez."
else
    echo "Bitti. PATH için yeni bir kabuk aç ya da 'source ~/.bashrc' çalıştır."
fi
if [ "$WITH_PANEL" -eq 1 ]; then
    echo "Panel: http://127.0.0.1:8090 (Pi üzerinde). Başka bir bilgisayardan:"
    echo "  ssh -L 8090:127.0.0.1:8090 $(id -un)@$(hostname).local   sonra tarayıcıda http://localhost:8090"
fi
echo "Başlamak için: pisec --help"
echo "Komut notları: $CHEATSHEET"
[ "$missing" -eq 0 ] || exit 1
