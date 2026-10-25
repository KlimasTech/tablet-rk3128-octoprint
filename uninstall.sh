#!/bin/bash
# tablet-rk3128-octoprint — uninstaller
#
# Cofa zmiany wprowadzone przez install.sh: wyłącza i usuwa trzy usługi
# systemd, usuwa skrypt kamery i skrót kontrolny z pulpitu.
#
# CZEGO NIE RUSZA (celowo):
#   - instalacji OctoPrint, venv i profilu,
#   - pluginu bettergrblsupport,
#   - wpisów w config.yaml (zostają, ale są nieszkodliwe bez usług).
#   Żeby usunąć plugin:
#     sudo -u <OCTOPRINT_USER> <OCTOPRINT_VENV>/bin/python -m pip uninstall Better-Grbl-Support
#
# Użycie:
#   sudo ./uninstall.sh
#   sudo ./uninstall.sh --purge    # usuwa też skrypt kamery i profil kamery

set -euo pipefail

OCTOPRINT_VENV="${OCTOPRINT_VENV:-/home/printer/OctoPrint/venv}"
OCTOPRINT_USER="${OCTOPRINT_USER:-printer}"
DESKTOP_USER="${DESKTOP_USER:-tablet}"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Nieznany argument: $arg" >&2; exit 1 ;;
    esac
done

log()  { echo -e "\n\033[1;32m[uninstall]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[uwaga]\033[0m $*"; }
die()  { echo -e "\n\033[1;31m[blad]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Uruchom jako root: sudo $0"

DESKTOP_HOME="/home/${DESKTOP_USER}"

# ---------------------------------------------------------------------------
# 1. Zatrzymanie i wyłączenie usług
# ---------------------------------------------------------------------------
for unit in octoprint octoprint-webcam octoprint-serial-bridge; do
    if systemctl cat "${unit}.service" >/dev/null 2>&1; then
        log "Zatrzymuję i wyłączam ${unit}.service..."
        systemctl disable --now "${unit}" 2>/dev/null || true
    else
        log "${unit}.service nie istnieje, pomijam."
    fi
done

# ---------------------------------------------------------------------------
# 2. Usunięcie plików jednostek
# ---------------------------------------------------------------------------
log "Usuwam pliki jednostek systemd..."
for unit in octoprint octoprint-webcam octoprint-serial-bridge; do
    rm -f "/etc/systemd/system/${unit}.service"
done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Skrót i skrypt kontrolny
# ---------------------------------------------------------------------------
log "Usuwam skrót kontrolny z pulpitu..."
rm -f "${DESKTOP_HOME}/Desktop/OctoPrint.desktop"
rm -f "${DESKTOP_HOME}/octoprint-control.sh"

# ---------------------------------------------------------------------------
# 4. Serwer kamery (tylko z --purge — może być używany niezależnie)
# ---------------------------------------------------------------------------
if [[ "${PURGE}" == "1" ]]; then
    log "Usuwam serwer kamery (--purge)..."
    rm -f "${DESKTOP_HOME}/webcam_stream.py"
else
    warn "Skrypt kamery zostawiony: ${DESKTOP_HOME}/webcam_stream.py"
    warn "Usuń go przez: sudo $0 --purge"
fi

# ---------------------------------------------------------------------------
# 5. Pozostałości
# ---------------------------------------------------------------------------
if [[ -e /dev/ttyPlotter ]]; then
    log "Usuwam pozostały link /dev/ttyPlotter..."
    rm -f /dev/ttyPlotter
fi

log "Gotowe."
cat <<EOF

Usunieto: 3 uslugi systemd, skrot z pulpitu$( [[ "${PURGE}" == "1" ]] && echo ", serwer kamery" )

ZOSTAWIONE celowo:
  - OctoPrint, venv (${OCTOPRINT_VENV}) i profil
  - plugin bettergrblsupport
  - wpisy serial/classicwebcam w config.yaml

Jesli chcesz usunac takze plugin:
  sudo -u ${OCTOPRINT_USER} ${OCTOPRINT_VENV}/bin/python -m pip uninstall Better-Grbl-Support

Jesli chcesz wrocic do recznego uruchamiania OctoPrint z pulpitu,
przywroc oryginalny skrot OctoPrint.desktop z kopii zapasowej.
EOF
