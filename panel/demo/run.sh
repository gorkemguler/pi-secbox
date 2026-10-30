#!/usr/bin/env bash
#
# Paneli örnek verilerle ve girişsiz açar; sadece 127.0.0.1'de dinler.
# Arayüz geliştirme ve ekran görüntüleri için. Gerçek araç çalıştırmaz.
#
#   panel/demo/run.sh            http://127.0.0.1:8099
#   PORT=9000 panel/demo/run.sh
#
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$here/data/." "$work/"

export PISEC_PANEL_DEMO=1
export PISEC_OUT="$work/pisec-sonuclar"
export PISEC_STATE="$work/state"
export PISEC_APPS="$work/apps"
export PISEC_CONF_DIR="$work/conf"
export PISEC_UFW_CONF="$work/ufw.conf"
export PISEC_HOSTNAME="${PISEC_HOSTNAME:-pisecbox}"
export PISEC_BIN="$here/bin/pisec"
export DEMO_DELAY="${DEMO_DELAY:-1}"
export PATH="$here/bin:$PATH"

python3 "$here/../app.py" serve --host 127.0.0.1 --port "${PORT:-8099}"
