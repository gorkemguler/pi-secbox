# Testlerin ortak kurulumu: sahte araçları PATH'e koyar, HOME'u geçici bir
# dizine alır. Böylece testler gerçek ağa, Tor'a ya da kullanıcının dosyalarına
# dokunmuyor.

MOCKED_TOOLS=(curl tor-resolve proxychains4 sudo nmap subfinder dnsx httpx testssl nuclei ip systemctl
              systemd-analyze systemd-run cloudflared)

setup_mocks() {
    export MOCK_DIR=$BATS_TEST_TMPDIR
    export MOCK_LOG=$MOCK_DIR/calls.log
    mkdir -p "$MOCK_DIR/bin" "$MOCK_DIR/home"
    local t
    for t in "${MOCKED_TOOLS[@]}"; do
        ln -s "$BATS_TEST_DIRNAME/mock" "$MOCK_DIR/bin/$t"
    done
    : > "$MOCK_LOG"
    export PATH="$MOCK_DIR/bin:$PATH"
    export HOME=$MOCK_DIR/home
    export PISEC_OUT=$HOME/pisec-sonuclar
    export PISEC_SCOPE=$HOME/.config/pisec/kapsam
    export PISEC_STATE=$HOME/.local/state/pisec
    export PISEC_NOTIFY=1
    # Bu üç değişken .bats dosyalarında kullanılıyor.
    # shellcheck disable=SC2034
    PISEC=$BATS_TEST_DIRNAME/../pisec
    # shellcheck disable=SC2034
    SETUP=$BATS_TEST_DIRNAME/../setup.sh
    # shellcheck disable=SC2034
    UNINSTALL=$BATS_TEST_DIRNAME/../uninstall.sh
}

# Aracın çağrılarını gösterir; hiç çağrılmadıysa başarısız olur.
calls() {
    grep "^$1 " "$MOCK_LOG"
}

not_called() {
    if grep -q "^$1 " "$MOCK_LOG"; then
        echo "$1 çağrılmamalıydı:" >&2
        grep "^$1 " "$MOCK_LOG" >&2
        return 1
    fi
}

latest_run() {
    find "$PISEC_OUT" -name ozet.md -exec dirname {} \; | LC_ALL=C sort | tail -n 1
}

latest_summary() {
    cat "$(latest_run)/ozet.md"
}
