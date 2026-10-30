#!/usr/bin/env bash
#
# pi-secbox kaldırma betiği
# setup.sh'ın yaptığı değişiklikleri geri alır. apt paketlerine ve kullanıcı
# verisine (tarama sonuçları, kapsam listesi, araç ayarları) varsayılan olarak dokunmaz.
#
set -euo pipefail

PDTM_DIR="$HOME/.pdtm"
TEMPLATES_DIR="$HOME/nuclei-templates"
CHEATSHEET="$HOME/pisecbox-cheatsheet.md"
TESTSSL_DIR="/opt/testssl.sh"
PROXYCHAINS_CONF="/etc/proxychains4.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/pisecbox.local"
PISEC_BIN="/usr/local/bin/pisec"
TESTSSL_LINK="/usr/local/bin/testssl"
PANEL_DIR="/usr/local/lib/pisec-panel"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CLOUDFLARE_KEY="/usr/share/keyrings/cloudflare-public-v2.gpg"
CLOUDFLARE_LIST="/etc/apt/sources.list.d/cloudflared.list"
PACKAGES=(nmap tcpdump tshark whois macchanger tor torsocks proxychains4 ufw fail2ban)
USER_DATA=(
    "$HOME/pisec-sonuclar" "$HOME/.config/pisec" "$HOME/.local/state/pisec" "$HOME/pisec-apps"
    "$HOME/.config/nuclei" "$HOME/.config/subfinder" "$HOME/.config/httpx"
    "$HOME/.config/naabu" "$HOME/.config/dnsx" "$HOME/.config/pdtm" "$HOME/.cache/nuclei"
)

DRY_RUN=0
ASSUME_YES=0
KEEP_FIREWALL=0
REMOVE_PACKAGES=0
PURGE=0

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Kullanım: ./uninstall.sh [seçenekler]

  -n, --dry-run     ne yapılacağını göster, hiçbir şeyi değiştirme
  -y, --yes         onay sorma
  --keep-firewall   ufw'yi açık bırak
  --packages        setup.sh'ın kurduğu güvenlik paketlerini de kaldır
                    (${PACKAGES[*]})
  --purge           tarama sonuçlarını, kapsam listesini, panel ayarlarını,
                    Cloudflare token'ını ve ~/pisec-apps'i de sil
  -h, --help        bu yardımı göster
EOF
}

# Komutu yazar ve çalıştırır; --dry-run'da sadece yazar.
do_() {
    printf '    %s\n' "$*"
    if [ "$DRY_RUN" -eq 0 ]; then "$@"; fi
}

# setup.sh'ın .bashrc'ye eklediği bloğu (öncesindeki boş satırla birlikte) siler.
strip_bashrc_block() {
    awk '
        {
            if (held) {
                held = 0
                if ($0 == "# pi-secbox") { skip = 1; next }
                print ""
            }
            if (skip) {
                skip = 0
                if ($0 ~ /^export PATH=.*\.pdtm\/go\/bin/) next
            }
            if ($0 == "") { held = 1; next }
            if ($0 == "# pi-secbox") { skip = 1; next }
            print
        }
        END { if (held) print "" }' "$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)    DRY_RUN=1 ;;
        -y|--yes)        ASSUME_YES=1 ;;
        --keep-firewall) KEEP_FIREWALL=1 ;;
        --packages)      REMOVE_PACKAGES=1 ;;
        --purge)         PURGE=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; die "Bilinmeyen seçenek: $1" ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || die "Betiği root olarak değil, kendi kullanıcınla çalıştır."

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    cat <<EOF
Bu betik setup.sh'ın kurduklarını kaldıracak:
  - pisec, web paneli ve testssl.sh ($TESTSSL_DIR)
  - zamanlanmış taramalar, panel servisi, Cloudflare tünelleri
  - nuclei, subfinder, httpx, naabu, dnsx (~/.pdtm) ve ~/nuclei-templates
  - .bashrc'deki pi-secbox satırları ve ~/pisecbox-cheatsheet.md
  - proxychains4 ayarı (.orig yedeğinden geri yüklenir) ve fail2ban sshd ayarı
  - debian-tor grup üyeliği
EOF
    if [ "$KEEP_FIREWALL" -eq 0 ]; then echo "  - ufw kapatılacak (açık kalsın istersen --keep-firewall)"; fi
    if [ "$REMOVE_PACKAGES" -eq 1 ]; then echo "  - apt paketleri: ${PACKAGES[*]}"; fi
    if [ "$PURGE" -eq 1 ]; then echo "  - tarama sonuçları, kapsam listesi ve araç ayarları"; fi
    read -r -p "Devam edilsin mi? [e/H] " answer || answer=""
    [[ $answer =~ ^[eEyY] ]] || die "Vazgeçildi."
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Deneme modu: aşağıdaki komutlar çalıştırılmayacak."
else
    sudo -v
fi

log "Zamanlanmış görevler, panel ve tüneller"
shopt -s nullglob
units=("$UNIT_DIR"/pisec-*.service "$UNIT_DIR"/pisec-*.timer)
shopt -u nullglob
for u in "${units[@]}"; do
    do_ systemctl --user disable --now "$(basename "$u")"
done
# pisec publish ile açılan geçici tüneller dosyası olmayan, anlık birimler.
for u in $(systemctl --user list-units --plain --no-legend 'pisec-publish-*' 2>/dev/null | awk '{ print $1 }'); do
    do_ systemctl --user stop "$u"
done
for u in "${units[@]}"; do do_ rm -f "$u"; done
if [ ${#units[@]} -gt 0 ]; then do_ systemctl --user daemon-reload; fi

log "pisec, panel ve testssl.sh"
if [ -e "$PISEC_BIN" ]; then do_ sudo rm -f "$PISEC_BIN"; fi
if [ -d "$PANEL_DIR" ]; then do_ sudo rm -rf "$PANEL_DIR"; fi
if [ -L "$TESTSSL_LINK" ]; then do_ sudo rm -f "$TESTSSL_LINK"; fi
if [ -d "$TESTSSL_DIR" ]; then do_ sudo rm -rf "$TESTSSL_DIR"; fi

log "ProjectDiscovery araçları, nuclei şablonları, komut notları"
if [ -d "$PDTM_DIR" ]; then do_ rm -rf "$PDTM_DIR"; fi
if [ -d "$TEMPLATES_DIR" ]; then do_ rm -rf "$TEMPLATES_DIR"; fi
if [ -f "$CHEATSHEET" ]; then do_ rm -f "$CHEATSHEET"; fi

log ".bashrc"
if grep -qxF '# pi-secbox' "$HOME/.bashrc" 2>/dev/null; then
    echo "    pi-secbox bloğu siliniyor, eski hali ~/.bashrc.pisecbox-yedek olarak saklanıyor"
    if [ "$DRY_RUN" -eq 0 ]; then
        cp -p "$HOME/.bashrc" "$HOME/.bashrc.pisecbox-yedek"
        tmp=$(mktemp)
        strip_bashrc_block "$HOME/.bashrc" > "$tmp"
        # mv yerine cat: dosyanın izinleri ve sahibi değişmesin.
        cat "$tmp" > "$HOME/.bashrc"
        rm -f "$tmp"
    fi
else
    echo "    pi-secbox bloğu yok."
fi

log "proxychains4 ve fail2ban"
if [ -f "$PROXYCHAINS_CONF.orig" ]; then do_ sudo mv "$PROXYCHAINS_CONF.orig" "$PROXYCHAINS_CONF"; fi
if [ -f "$FAIL2BAN_JAIL" ]; then
    do_ sudo rm -f "$FAIL2BAN_JAIL"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then do_ sudo systemctl restart fail2ban; fi
fi

log "debian-tor grubu"
if getent group debian-tor | cut -d: -f4 | tr ',' '\n' | grep -x "$(id -un)" >/dev/null; then
    do_ sudo gpasswd -d "$(id -un)" debian-tor
fi

log "ufw"
if [ "$KEEP_FIREWALL" -eq 1 ]; then
    echo "    --keep-firewall verildi, dokunulmadı."
elif [ -x /usr/sbin/ufw ]; then
    do_ sudo ufw --force disable
fi

if [ "$REMOVE_PACKAGES" -eq 1 ]; then
    log "apt paketleri"
    installed=()
    for p in "${PACKAGES[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then installed+=("$p"); fi
    done
    if dpkg -s cloudflared >/dev/null 2>&1; then installed+=(cloudflared); fi
    if [ ${#installed[@]} -gt 0 ]; then
        do_ sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q remove --autoremove "${installed[@]}"
    fi
    if [ -f "$CLOUDFLARE_LIST" ]; then do_ sudo rm -f "$CLOUDFLARE_LIST" "$CLOUDFLARE_KEY"; fi
fi

if [ "$PURGE" -eq 1 ]; then
    log "Tarama sonuçları ve araç ayarları"
    for d in "${USER_DATA[@]}"; do
        if [ -e "$d" ]; then do_ rm -rf "$d"; fi
    done
fi

echo
echo "Bitti."
if [ "$REMOVE_PACKAGES" -eq 0 ]; then
    echo "apt paketleri ve servisleri (tor, fail2ban) yerinde. Kaldırmak için: ./uninstall.sh --packages"
fi
if [ "$PURGE" -eq 0 ]; then
    echo "Tarama sonuçları (~/pisec-sonuclar), kapsam listesi ve araç ayarları duruyor. Silmek için: --purge"
fi
echo "Dokunulmayanlar: Docker ve konteynerler, Pi Connect, kullanıcı servisleri için açılan linger"
echo "(kapatmak için: sudo loginctl disable-linger $(id -un))."
