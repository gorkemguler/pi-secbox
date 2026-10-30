#!/usr/bin/env bats
#
# setup.sh ve uninstall.sh testleri. setup.sh sistemi değiştirdiği için sadece
# seçenek ayrıştırması deneniyor; uninstall.sh sahte HOME ve hiçbir şey
# çalıştırmayan sahte sudo ile deneniyor.

load helpers

setup() {
    setup_mocks
    export MOCK_SUDO_NOEXEC=1
}

make_fake_install() {
    mkdir -p "$HOME/.pdtm/go/bin" "$HOME/nuclei-templates" "$HOME/pisec-sonuclar/hedef.com" "$HOME/.config/pisec"
    touch "$HOME/pisecbox-cheatsheet.md"
    mkdir -p "$HOME/.config/systemd/user"
    touch "$HOME/.config/systemd/user/pisec-job-recon-hedef.com.timer" "$HOME/.config/systemd/user/pisec-job-recon-hedef.com.service"
    # shellcheck disable=SC2016
    printf '%s\n' '# kullanıcının kendi ayarları' 'alias ll="ls -l"' '' '# pi-secbox' \
        'export PATH="$HOME/.pdtm/go/bin:$PATH"' > "$HOME/.bashrc"
}

@test "setup.sh --help kullanımı gösterir" {
    run "$SETUP" --help
    [ "$status" -eq 0 ]
    [[ $output == *"--no-upgrade"* ]]
    [[ $output == *"--with-panel"* ]]
}

@test "setup.sh bilinmeyen seçenekte hiçbir şey yapmadan durur" {
    run "$SETUP" --hepsini-kur
    [ "$status" -eq 1 ]
    [[ $output == *"Bilinmeyen seçenek"* ]]
    [ ! -s "$MOCK_LOG" ]
}

@test "uninstall.sh --dry-run hiçbir şeyi değiştirmez" {
    make_fake_install
    run "$UNINSTALL" --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"rm -rf $HOME/.pdtm"* ]]
    [ -d "$HOME/.pdtm" ]
    [ -d "$HOME/nuclei-templates" ]
    grep -qxF '# pi-secbox' "$HOME/.bashrc"
    [ ! -e "$HOME/.bashrc.pisecbox-yedek" ]
}

@test "uninstall.sh kurulan dosyaları ve .bashrc bloğunu kaldırır, sonuçlara dokunmaz" {
    make_fake_install
    run "$UNINSTALL" -y
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.pdtm" ]
    [ ! -e "$HOME/nuclei-templates" ]
    [ ! -e "$HOME/pisecbox-cheatsheet.md" ]
    [ ! -e "$HOME/.config/systemd/user/pisec-job-recon-hedef.com.timer" ]
    calls systemctl | grep -q 'disable --now pisec-job-recon-hedef.com.timer'
    diff "$HOME/.bashrc" <(printf '%s\n' '# kullanıcının kendi ayarları' 'alias ll="ls -l"')
    grep -qxF '# pi-secbox' "$HOME/.bashrc.pisecbox-yedek"
    [ -d "$HOME/pisec-sonuclar/hedef.com" ]
    [ -d "$HOME/.config/pisec" ]
}

@test "uninstall.sh --purge tarama sonuçlarını ve kapsam listesini de siler" {
    make_fake_install
    run "$UNINSTALL" -y --purge
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/pisec-sonuclar" ]
    [ ! -e "$HOME/.config/pisec" ]
}

@test "uninstall.sh onay verilmezse hiçbir şeyi silmez" {
    make_fake_install
    run "$UNINSTALL" <<<"hayir"
    [ "$status" -eq 1 ]
    [[ $output == *"Vazgeçildi"* ]]
    [ -d "$HOME/.pdtm" ]
}

@test "uninstall.sh bilinmeyen seçenekte durur" {
    run "$UNINSTALL" --hepsi
    [ "$status" -eq 1 ]
    [[ $output == *"Bilinmeyen seçenek"* ]]
}
