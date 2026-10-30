#!/usr/bin/env bash
#
# pi-secbox kurulum betiği
# Raspberry Pi OS Lite üzerine ağ keşfi / denetim araçlarını, Tor + proxychains'i
# ve temel sıkılaştırmayı (ufw, fail2ban) kurar. Birden fazla kez çalıştırılabilir.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_UPGRADE=1
DO_FIREWALL=1
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

  --no-upgrade    apt full-upgrade adımını atla
  --no-firewall   ufw ayarlarına dokunma
  -h, --help      bu yardımı göster
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
    bsdextrautils procps
)

# Masaüstü sürümünde rpi-connect kurulu olabilir, lite paketi onunla çakışıyor.
if dpkg -s rpi-connect >/dev/null 2>&1; then
    :
elif apt-cache show rpi-connect-lite >/dev/null 2>&1; then
    PACKAGES+=(rpi-connect-lite)
else
    warn "rpi-connect-lite depoda yok (Raspberry Pi OS değil mi?), atlanıyor."
fi

log "Paketler kuruluyor"
apt_get install "${PACKAGES[@]}"

# Pi Connect kullanıcı servisi olarak çalışıyor; oturum kapalıyken de ayakta kalsın.
if dpkg -s rpi-connect-lite >/dev/null 2>&1 || dpkg -s rpi-connect >/dev/null 2>&1; then
    sudo loginctl enable-linger "$(id -un)"
fi

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

# --- Komut notları ------------------------------------------------------------

if [ -f "$SCRIPT_DIR/cheatsheet.md" ]; then
    install -m 644 "$SCRIPT_DIR/cheatsheet.md" "$CHEATSHEET"
else
    warn "cheatsheet.md bulunamadı, komut notları kopyalanmadı."
fi

# --- Kontrol ------------------------------------------------------------------

log "Kurulan araçlar"
missing=0
for t in nmap tshark tor proxychains4 pdtm nuclei subfinder httpx naabu dnsx testssl; do
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
echo "Bitti. PATH için yeni bir kabuk aç ya da 'source ~/.bashrc' çalıştır."
echo "Komut notları: $CHEATSHEET"
[ "$missing" -eq 0 ] || exit 1
