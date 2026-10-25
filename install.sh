#!/bin/bash
# tablet-rk3128-octoprint — installer
#
# Dopina istniejącą instalację OctoPrint (np. na przemysłowym tablecie
# RK3128 z projektu plotter-doctor/industrial_tablet) do fizycznego
# plotera/CNC po GRBL wystawionym jako TCP (serial-over-tcp), dodaje
# wsparcie dla kamery USB, i opakowuje wszystko w usługi systemd tak,
# żeby przetrwało restart.
#
# WYMAGA: root (sudo), istniejącej instalacji OctoPrint w venv, socat,
# python3 + python3-opencv (do kamery; opcjonalne).
#
# Użycie:
#   sudo ./install.sh
#   ./install.sh --help               # opis wszystkich zmiennych
# Konfiguracja przez zmienne środowiskowe (patrz README.md), np.:
#   sudo OCTOPRINT_VENV=/home/printer/OctoPrint/venv \
#        OCTOPRINT_USER=printer \
#        DESKTOP_USER=tablet \
#        GRBL_TCP_PORT=8888 \
#        ./install.sh
#
# Skrypt jest idempotentny — można go uruchamiać wielokrotnie.

set -euo pipefail

# ---------------------------------------------------------------------------
# Konfiguracja (nadpisywalna zmiennymi środowiskowymi)
# ---------------------------------------------------------------------------
OCTOPRINT_VENV="${OCTOPRINT_VENV:-/home/printer/OctoPrint/venv}"
OCTOPRINT_USER="${OCTOPRINT_USER:-printer}"           # właściciel venv/pip
DESKTOP_USER="${DESKTOP_USER:-tablet}"                # user uruchamiający serwer/GUI
SERIAL_LINK="${SERIAL_LINK:-/dev/ttyPlotter}"         # trwały wirtualny port
GRBL_TCP_HOST="${GRBL_TCP_HOST:-127.0.0.1}"
GRBL_TCP_PORT="${GRBL_TCP_PORT:-8888}"
SERIAL_BAUDRATE="${SERIAL_BAUDRATE:-115200}"
PRINTER_PROFILE="${PRINTER_PROFILE:-_bgs}"            # profil bettergrblsupport
WEBCAM_ENABLE="${WEBCAM_ENABLE:-1}"                   # 0 = pomiń kamerę
WEBCAM_DEVICE_INDEX="${WEBCAM_DEVICE_INDEX:-0}"
WEBCAM_PORT="${WEBCAM_PORT:-8080}"
WEBCAM_PUBLIC_HOST="${WEBCAM_PUBLIC_HOST:-}"          # adres kamery widziany z przeglądarki
INSTALL_DESKTOP_SHORTCUTS="${INSTALL_DESKTOP_SHORTCUTS:-1}"
SKIP_PLUGIN_INSTALL="${SKIP_PLUGIN_INSTALL:-0}"       # 1 = nie instaluj bettergrblsupport
FIX_VENV_PERMISSIONS="${FIX_VENV_PERMISSIONS:-1}"     # 1 = napraw prawa venv (Plugin Manager)
ENABLE_OCTOPRINT_AUTOSTART="${ENABLE_OCTOPRINT_AUTOSTART:-1}"  # 1 = usługa startuje z systemem

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_HOME="/home/${DESKTOP_USER}"
OCTOPRINT_BASEDIR="${OCTOPRINT_BASEDIR:-${DESKTOP_HOME}/.octoprint}"
WEBCAM_SCRIPT_PATH="${DESKTOP_HOME}/webcam_stream.py"

log()  { echo -e "\n\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[uwaga]\033[0m $*"; }
die()  { echo -e "\n\033[1;31m[blad]\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
tablet-rk3128-octoprint — instalator

Uruchomienie:
  sudo ./install.sh

Zmienne środowiskowe (wszystkie opcjonalne, pokazane wartości domyślne):

  OCTOPRINT_VENV             /home/printer/OctoPrint/venv
      Ścieżka do istniejącego venv OctoPrint (musi zawierać bin/python).

  OCTOPRINT_USER             printer
      Właściciel venv / user używany przez pip.

  DESKTOP_USER               tablet
      User, jako który działa serwer OctoPrint, kamera i skróty pulpitu.

  OCTOPRINT_BASEDIR          /home/<DESKTOP_USER>/.octoprint
      Katalog profilu OctoPrint (musi zawierać config.yaml).

  SERIAL_LINK                /dev/ttyPlotter
      Trwały wirtualny port szeregowy tworzony przez socat.

  GRBL_TCP_HOST/GRBL_TCP_PORT    127.0.0.1 / 8888
      Adres mostu TCP wystawiającego GRBL (serial-over-tcp).

  SERIAL_BAUDRATE            115200

  PRINTER_PROFILE            _bgs
      ID profilu drukarki bettergrblsupport.

  WEBCAM_ENABLE              1        (0 = pomiń kamerę)
  WEBCAM_DEVICE_INDEX        0        (/dev/videoN)
  WEBCAM_PORT                8080
  WEBCAM_PUBLIC_HOST         (auto)
      Adres, pod którym kamera ma być widoczna z przeglądarki klienta.
      Domyślnie wykrywany automatycznie (adres LAN tabletu). Ustaw ręcznie
      jeśli tablet ma wiele interfejsów lub jest za NAT-em.

  INSTALL_DESKTOP_SHORTCUTS  1        (0 = bez skrótów na pulpicie)
  SKIP_PLUGIN_INSTALL        0        (1 = nie instaluj bettergrblsupport)
  FIX_VENV_PERMISSIONS       1        (1 = nadaj userowi usługi prawa zapisu do venv)
  ENABLE_OCTOPRINT_AUTOSTART 1        (1 = octoprint.service startuje z systemem)
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        *) die "Nieznany argument: $arg (użyj --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Uruchom jako root: sudo $0"

PYTHON_BIN="${OCTOPRINT_VENV}/bin/python"
[[ -x "$PYTHON_BIN" ]] || die "Nie znaleziono ${PYTHON_BIN} — ustaw OCTOPRINT_VENV na istniejący venv OctoPrint."
[[ -f "${OCTOPRINT_BASEDIR}/config.yaml" ]] || die "Nie znaleziono ${OCTOPRINT_BASEDIR}/config.yaml — ustaw OCTOPRINT_BASEDIR na istniejący profil."
id -u "${DESKTOP_USER}" >/dev/null 2>&1 || die "User '${DESKTOP_USER}' nie istnieje."
id -u "${OCTOPRINT_USER}" >/dev/null 2>&1 || die "User '${OCTOPRINT_USER}' nie istnieje."

for cmd in socat systemctl runuser; do
    command -v "$cmd" >/dev/null 2>&1 || die "Wymagana komenda '$cmd' nie jest zainstalowana."
done
SOCAT_BIN="$(command -v socat)"
VENV_GROUP="$(id -gn "${DESKTOP_USER}")"

# Adres, pod którym przeglądarka klienta widzi kamerę. NIE może to być
# 127.0.0.1 — przeglądarka rozwiąże ten adres na własnej maszynie i podgląd
# z kamery będzie pusty przy dostępie zdalnym.
detect_lan_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip route get 1.1.1.1 2>/dev/null \
              | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')" || true
    fi
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
    fi
    printf '%s' "$ip"
}

if [[ "${WEBCAM_ENABLE}" == "1" && -z "${WEBCAM_PUBLIC_HOST}" ]]; then
    WEBCAM_PUBLIC_HOST="$(detect_lan_ip)"
    [[ -n "${WEBCAM_PUBLIC_HOST}" ]] || die "Nie udało się wykryć adresu LAN — ustaw WEBCAM_PUBLIC_HOST ręcznie."
    log "Wykryty adres kamery (WEBCAM_PUBLIC_HOST): ${WEBCAM_PUBLIC_HOST}"
fi

log "Konfiguracja:"
cat <<EOF
  OCTOPRINT_VENV     = ${OCTOPRINT_VENV}
  OCTOPRINT_USER     = ${OCTOPRINT_USER}
  DESKTOP_USER       = ${DESKTOP_USER}
  OCTOPRINT_BASEDIR  = ${OCTOPRINT_BASEDIR}
  SERIAL_LINK        = ${SERIAL_LINK}
  GRBL_TCP           = ${GRBL_TCP_HOST}:${GRBL_TCP_PORT}
  PRINTER_PROFILE    = ${PRINTER_PROFILE}
  WEBCAM_ENABLE      = ${WEBCAM_ENABLE} (device /dev/video${WEBCAM_DEVICE_INDEX}, port ${WEBCAM_PORT}, host ${WEBCAM_PUBLIC_HOST:-brak})
  AUTOSTART          = ${ENABLE_OCTOPRINT_AUTOSTART}
EOF

# ---------------------------------------------------------------------------
# 1. Uprawnienia venv
#
#    Dwa niezależne problemy do naprawienia jednocześnie:
#      a) user usługi (DESKTOP_USER) musi móc CZYTAĆ pakiety — inaczej przy
#         starcie dostaje "ImportError: cannot import name 'main' from
#         'octoprint'", gdy venv należy do innego użytkownika z prawami 700.
#      b) user usługi musi móc PISAĆ do site-packages — inaczej Plugin
#         Manager w UI zgłasza "The pip command could not be found or does
#         not work correctly ... No installation and uninstallation of
#         plugin packages is possible".
#    Rozwiązanie: grupa venv = grupa główna usera usługi + g+rwX.
#    (Nie zmieniamy właściciela — venv może być współdzielony.)
# ---------------------------------------------------------------------------
fix_venv_permissions() {
    chown -R "${OCTOPRINT_USER}:${VENV_GROUP}" "${OCTOPRINT_VENV}"
    chmod -R g+rwX "${OCTOPRINT_VENV}"
    # Ścieżki nadrzędne też muszą być przechodnie dla usera usługi.
    chmod a+rX "$(dirname "${OCTOPRINT_VENV}")" 2>/dev/null || true
}

if [[ "${FIX_VENV_PERMISSIONS}" == "1" ]]; then
    log "Naprawiam uprawnienia venv (grupa ${VENV_GROUP}, g+rwX)..."
    fix_venv_permissions
else
    warn "FIX_VENV_PERMISSIONS=0 — pomijam naprawę uprawnień venv."
    warn "Jeśli usługa działa jako inny user niż właściciel venv, mogą wystąpić"
    warn "błędy ImportError przy starcie lub brak działania Plugin Managera."
fi

# ---------------------------------------------------------------------------
# 2. Plugin bettergrblsupport (GRBL/CNC/laser support dla OctoPrint)
# ---------------------------------------------------------------------------
if [[ "${SKIP_PLUGIN_INSTALL}" != "1" ]]; then
    if "${PYTHON_BIN}" -m pip show Better-Grbl-Support >/dev/null 2>&1; then
        log "Plugin bettergrblsupport już zainstalowany, pomijam."
    else
        log "Instaluję plugin bettergrblsupport..."
        # --no-build-isolation jest WYMAGANE: domyślne izolowane środowisko
        # budowania pip nie widzi octoprint_setuptools zainstalowanego w tym
        # samym venv, inaczej błąd "Could not import OctoPrint's setuptools".
        runuser -u "${OCTOPRINT_USER}" -- env "HOME=/home/${OCTOPRINT_USER}" \
            "${PYTHON_BIN}" -m pip install --no-cache-dir --no-build-isolation \
            "https://github.com/synman/OctoPrint-Bettergrblsupport/archive/refs/heads/master.zip" \
            || die "Instalacja pluginu bettergrblsupport nie powiodła się."
        # pip potrafi zapisać nowe pliki z zawężonymi prawami (umask 077) —
        # naprawiamy od razu, inaczej user usługi nie odczyta pakietu.
        if [[ "${FIX_VENV_PERMISSIONS}" == "1" ]]; then
            fix_venv_permissions
        fi
    fi
else
    log "SKIP_PLUGIN_INSTALL=1 — pomijam instalację pluginu."
fi

# ---------------------------------------------------------------------------
# 3. Wirtualny port szeregowy (socat) -> most TCP do GRBL
#
#    OctoPrint NIE akceptuje "socket://host:port" jako portu połączenia —
#    jego lista portów (serialList()) filtruje additionalPorts przez glob()
#    na systemie plików, a URL-e nie są plikami, więc zawsze wypadają z
#    listy ("port is invalid"). socat tworzy prawdziwy plik-urządzenie
#    (PTY), który glob() znajduje normalnie.
#
#    WAŻNE: do portu GRBL_TCP_PORT może być podłączony tylko JEDEN klient
#    na raz (serial-over-tcp zwykle działa w trybie socat "fork", gdzie
#    każde nowe połączenie TCP dostaje świeży proces niezależnie czytający
#    ten sam port szeregowy — przy >=2 klientach odpowiedzi GRBL się
#    przeplatają/gubią między procesami). Zamknij bCNC/Candle/inne sendery
#    przed użyciem tego mostu, i odwrotnie.
# ---------------------------------------------------------------------------
log "Instaluję usługę mostu szeregowego (${SERIAL_LINK} -> ${GRBL_TCP_HOST}:${GRBL_TCP_PORT})..."
sed \
    -e "s#__SERIAL_LINK__#${SERIAL_LINK}#g" \
    -e "s#__GRBL_TCP_HOST__#${GRBL_TCP_HOST}#g" \
    -e "s#__GRBL_TCP_PORT__#${GRBL_TCP_PORT}#g" \
    -e "s#__SOCAT_BIN__#${SOCAT_BIN}#g" \
    -e "s#__DESKTOP_USER__#${DESKTOP_USER}#g" \
    "${SCRIPT_DIR}/systemd/octoprint-serial-bridge.service.template" \
    > /etc/systemd/system/octoprint-serial-bridge.service

# ---------------------------------------------------------------------------
# 4. Kamera USB -> serwer MJPEG (fallback gdy brak mjpg-streamer/apt)
# ---------------------------------------------------------------------------
if [[ "${WEBCAM_ENABLE}" == "1" ]]; then
    if command -v mjpg_streamer >/dev/null 2>&1; then
        warn "mjpg_streamer jest zainstalowany — ten installer i tak postawi"
        warn "własny prosty serwer OpenCV na porcie ${WEBCAM_PORT}, żeby nie"
        warn "kolidować z Twoją istniejącą konfiguracją mjpg_streamer."
    fi
    [[ -e "/dev/video${WEBCAM_DEVICE_INDEX}" ]] \
        || die "/dev/video${WEBCAM_DEVICE_INDEX} nie istnieje. Sprawdź WEBCAM_DEVICE_INDEX albo ustaw WEBCAM_ENABLE=0."
    runuser -u "${DESKTOP_USER}" -- python3 -c "import cv2" 2>/dev/null \
        || die "python3-opencv (cv2) nie jest dostępne dla usera ${DESKTOP_USER}. Zainstaluj (apt install python3-opencv) albo ustaw WEBCAM_ENABLE=0."

    log "Instaluję serwer kamery MJPEG (port ${WEBCAM_PORT})..."
    install -m 755 -o "${DESKTOP_USER}" -g "${DESKTOP_USER}" \
        "${SCRIPT_DIR}/scripts/webcam_stream.py" "${WEBCAM_SCRIPT_PATH}"

    sed \
        -e "s#__DESKTOP_USER__#${DESKTOP_USER}#g" \
        -e "s#__WEBCAM_DEVICE_PATH__#/dev/video${WEBCAM_DEVICE_INDEX}#g" \
        -e "s#__WEBCAM_DEVICE_INDEX__#${WEBCAM_DEVICE_INDEX}#g" \
        -e "s#__WEBCAM_PORT__#${WEBCAM_PORT}#g" \
        -e "s#__WEBCAM_SCRIPT_PATH__#${WEBCAM_SCRIPT_PATH}#g" \
        "${SCRIPT_DIR}/systemd/octoprint-webcam.service.template" \
        > /etc/systemd/system/octoprint-webcam.service
else
    log "WEBCAM_ENABLE=0 — pomijam kamerę."
fi

# ---------------------------------------------------------------------------
# 5. Usługa OctoPrint
# ---------------------------------------------------------------------------
log "Instaluję usługę octoprint.service..."
sed \
    -e "s#__DESKTOP_USER__#${DESKTOP_USER}#g" \
    -e "s#__OCTOPRINT_VENV__#${OCTOPRINT_VENV}#g" \
    "${SCRIPT_DIR}/systemd/octoprint.service.template" \
    > /etc/systemd/system/octoprint.service

systemctl daemon-reload

# ---------------------------------------------------------------------------
# 6. Konfiguracja OctoPrint (serial + webcam) w config.yaml
#
#    OctoPrint zapisuje swoje ustawienia do config.yaml przy zmianie i przy
#    zamykaniu — edycja pliku na działającym procesie zostałaby nadpisana.
#    Dlatego najpierw ZATRZYMUJEMY usługę, potem edytujemy, potem startujemy.
# ---------------------------------------------------------------------------
log "Zatrzymuję OctoPrint przed edycją config.yaml (unikamy nadpisania zmian)..."
systemctl stop octoprint 2>/dev/null || true

log "Konfiguruję serial/webcam w ${OCTOPRINT_BASEDIR}/config.yaml..."
runuser -u "${DESKTOP_USER}" -- "${PYTHON_BIN}" - \
    "${OCTOPRINT_BASEDIR}/config.yaml" "${WEBCAM_ENABLE}" <<PYEOF
import sys
import yaml

path = sys.argv[1]
webcam_enabled = sys.argv[2] == "1"

with open(path) as f:
    config = yaml.safe_load(f) or {}

config.setdefault("serial", {})
config["serial"]["additionalPorts"] = ["${SERIAL_LINK}"]
config["serial"]["port"] = "${SERIAL_LINK}"
config["serial"]["baudrate"] = ${SERIAL_BAUDRATE}
config["serial"]["autoconnect"] = True

if webcam_enabled:
    config.setdefault("plugins", {}).setdefault("classicwebcam", {})
    config["plugins"]["classicwebcam"]["stream"] = "http://${WEBCAM_PUBLIC_HOST}:${WEBCAM_PORT}/stream.mjpg"
    config["plugins"]["classicwebcam"]["snapshot"] = "http://${WEBCAM_PUBLIC_HOST}:${WEBCAM_PORT}/snapshot.jpg"

with open(path, "w") as f:
    yaml.safe_dump(config, f, default_flow_style=False)

print("config.yaml zaktualizowany.")
PYEOF

# ---------------------------------------------------------------------------
# 7. Włączenie usług
# ---------------------------------------------------------------------------
log "Włączam usługi..."
systemctl enable --now octoprint-serial-bridge
if [[ "${WEBCAM_ENABLE}" == "1" ]]; then
    systemctl enable --now octoprint-webcam
fi

if [[ "${ENABLE_OCTOPRINT_AUTOSTART}" == "1" ]]; then
    systemctl enable --now octoprint
else
    systemctl start octoprint
    warn "ENABLE_OCTOPRINT_AUTOSTART=0 — usługa nie startuje z systemem."
    warn "Włącz później: sudo systemctl enable octoprint"
fi

log "Czekam aż OctoPrint wstanie..."
for _ in $(seq 1 30); do
    if runuser -u "${DESKTOP_USER}" -- python3 -c "
import urllib.request
urllib.request.urlopen('http://127.0.0.1:5000/api/version', timeout=2)
" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# 8. Skróty na pulpicie (opcjonalne)
# ---------------------------------------------------------------------------
if [[ "${INSTALL_DESKTOP_SHORTCUTS}" == "1" && -d "${DESKTOP_HOME}/Desktop" ]]; then
    log "Instaluję skrót kontrolny na pulpicie..."
    install -m 755 -o "${DESKTOP_USER}" -g "${DESKTOP_USER}" \
        "${SCRIPT_DIR}/scripts/octoprint-control.sh" "${DESKTOP_HOME}/octoprint-control.sh"
    cat > "${DESKTOP_HOME}/Desktop/OctoPrint.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=OctoPrint Server
Comment=Kontrola usługi OctoPrint (systemd): start/stop/restart/autostart
Exec=bash ${DESKTOP_HOME}/octoprint-control.sh
Icon=utilities-terminal
Terminal=true
Categories=Development;Engineering;
EOF
    chmod 755 "${DESKTOP_HOME}/Desktop/OctoPrint.desktop"
    chown "${DESKTOP_USER}:${DESKTOP_USER}" "${DESKTOP_HOME}/Desktop/OctoPrint.desktop"
fi

# ---------------------------------------------------------------------------
# 9. Podsumowanie
# ---------------------------------------------------------------------------
log "Gotowe. Status usług:"
for unit in octoprint-serial-bridge octoprint-webcam octoprint; do
    if systemctl cat "${unit}.service" >/dev/null 2>&1; then
        printf '  %-28s %s / %s\n' "${unit}" \
            "$(systemctl is-active "${unit}" 2>/dev/null || true)" \
            "$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
    fi
done

cat <<EOF

Nastepne kroki:
  1. Otworz panel: http://<IP-tabletu>:5000
     Jesli nie masz jeszcze konta: Settings -> Users, albo z CLI:
       sudo -u ${DESKTOP_USER} ${OCTOPRINT_VENV}/bin/octoprint user password admin --password 'twoje-haslo'
  2. Sprawdz polaczenie: Connection -> port ${SERIAL_LINK}, profil ${PRINTER_PROFILE}
  3. Jesli ktos inny (bCNC, Candle...) laczy sie jednoczesnie z portem
     ${GRBL_TCP_PORT} -- ROZLACZ GO, most wspiera tylko jednego klienta naraz.
  4. Zarzadzanie usluga: sudo systemctl {start|stop|restart|enable|disable} octoprint
  5. Diagnostyka: docs/TROUBLESHOOTING.md

Jesli cokolwiek nie dziala:
  systemctl status octoprint octoprint-serial-bridge octoprint-webcam
  journalctl -u octoprint -n 50 --no-pager
EOF
