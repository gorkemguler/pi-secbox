#!/usr/bin/env bash
#
# pi-secbox kurulum betiği
# Raspberry Pi OS Lite üzerine ağ keşfi / denetim araçlarını, Tor + proxychains'i
# ve temel sıkılaştırmayı (ufw, fail2ban) kurar. Birden fazla kez çalıştırılabilir.
#
set -euo pipefail

PDTM_TOOLS="nuclei,subfinder,httpx,naabu,dnsx"
PDTM_BIN="$HOME/.pdtm/go/bin"
TESTSSL_DIR="/opt/testssl.sh"
TESTSSL_BRANCH="3.2"
PROXYCHAINS_CONF="/etc/proxychains4.conf"
CHEATSHEET="$HOME/pisecbox-cheatsheet.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_UPGRADE=1
DO_FIREWALL=1

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Kullanım: ./setup.sh [seçenekler]

  --no-upgrade    apt upgrade adımını atla
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
    sudo loginctl enable-linger "$USER"
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
    [ -n "$tag" ] && [ "$tag" != "null" ] || die "pdtm sürüm bilgisi alınamadı."
    ver=${tag#v}
    zip="pdtm_${ver}_linux_${ARCH}.zip"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    base="https://github.com/projectdiscovery/pdtm/releases/download/$tag"
    curl -fsSL -o "$tmp/$zip" "$base/$zip"
    curl -fsSL -o "$tmp/checksums.txt" "$base/pdtm_${ver}_checksums.txt"
    (cd "$tmp" && grep "  $zip\$" checksums.txt | sha256sum -c --quiet -) \
        || die "pdtm arşivinin SHA256 doğrulaması başarısız."
    unzip -o -q "$tmp/$zip" pdtm -d "$tmp"
    mkdir -p "$PDTM_BIN"
    install -m 755 "$tmp/pdtm" "$PDTM_BIN/pdtm"
fi

log "nuclei, subfinder, httpx, naabu ve dnsx kuruluyor / güncelleniyor"
pdtm -duc -dc -nc -i "$PDTM_TOOLS"
pdtm -duc -dc -nc -u "$PDTM_TOOLS"

log "Nuclei şablonları güncelleniyor"
nuclei -update-templates -silent || warn "Şablonlar indirilemedi, sonra 'nuclei -ut' ile tekrar dene."

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

# Debian 12 ve sonrasında /var/log/auth.log yok; sshd jail'i journald'dan okumazsa
# fail2ban hiç açılmıyor.
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
