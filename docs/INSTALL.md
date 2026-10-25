# Instalacja

## Wariant A — instalator (zalecany)

### 1. Sprawdź wymagania

```bash
# czy jest OctoPrint w venv
ls -l /home/<user>/OctoPrint/venv/bin/python

# czy jest socat (jeśli nie: sudo apt install socat)
command -v socat

# czy GRBL jest wystawiony po TCP
ss -tlnp | grep 8888
```

### 2. Pobierz repozytorium

```bash
git clone https://github.com/KlimasTech/tablet-rk3128-octoprint.git
cd tablet-rk3128-octoprint
```

### 3. Sprawdź konfigurację

```bash
./install.sh --help
```

Jeśli Twoja instalacja odbiega od domyślnej (inne ścieżki, inne konta), przygotuj zmienne — najczęściej wystarczy podać właściciela venv i usera usługi:

```bash
sudo OCTOPRINT_VENV=/home/printer/OctoPrint/venv \
     OCTOPRINT_USER=printer \
     DESKTOP_USER=tablet \
     ./install.sh
```

### 4. Uruchom

```bash
sudo ./install.sh
```

Skrypt wypisuje konfigurację, którą zastosuje, potem kolejno: naprawia uprawnienia venv, instaluje plugin, tworzy trzy usługi systemd, konfiguruje `config.yaml`, włącza usługi i zakłada skrót na pulpicie. Na końcu pokazuje status.

### 5. Pierwsze logowanie do panelu

Otwórz `http://<IP-tabletu>:5000`.

Jeśli nie masz jeszcze konta, utwórz je w UI (**Settings → Users**) albo z CLI:

```bash
sudo -u <DESKTOP_USER> <OCTOPRINT_VENV>/bin/octoprint user password admin --password 'twoje-haslo'
```

> Jeśli logowanie zwraca `403` mimo poprawnych danych — to rate limiter, nie złe hasło. `sudo systemctl restart octoprint`. Szczegóły: [TROUBLESHOOTING #6](TROUBLESHOOTING.md#6-logowanie-zwraca-403-mimo-poprawnych-danych).

### 6. Sprawdź połączenie z ploterem

W UI: **Connection** → port `/dev/ttyPlotter`, profil *Grbl Default Machine* → **Connect**. Stan powinien przejść w **Operational**.

Jeśli wisi na „Connecting” — ktoś inny siedzi na porcie GRBL: [TROUBLESHOOTING #4](TROUBLESHOOTING.md#4-połączenie-wisi-na-connecting--odpowiedzi-grbl-są-poszatkowane).

### 7. Sprawdź kamerę

Zakładka **Control** powinna pokazywać podgląd. Test serwera bezpośrednio:

```bash
wget -qO- http://127.0.0.1:8080/snapshot.jpg | wc -c
```

---

## Wariant B — instalacja ręczna

Gdy nie chcesz uruchamiać skryptu, albo chcesz zrozumieć każdy krok.

### B.1. Uprawnienia venv

```bash
sudo chown -R printer:$(id -gn tablet) /home/printer/OctoPrint/venv
sudo chmod -R g+rwX /home/printer/OctoPrint/venv
```

### B.2. Plugin bettergrblsupport

```bash
sudo -u printer env HOME=/home/printer \
  /home/printer/OctoPrint/venv/bin/python -m pip install --no-cache-dir --no-build-isolation \
  https://github.com/synman/OctoPrint-Bettergrblsupport/archive/refs/heads/master.zip
```

### B.3. Most szeregowy

Zapisz `/etc/systemd/system/octoprint-serial-bridge.service`:

```ini
[Unit]
Description=Virtual serial bridge /dev/ttyPlotter -> TCP 127.0.0.1:8888 (GRBL)
After=network.target
Before=octoprint.service

[Service]
Type=simple
ExecStartPre=/bin/rm -f /dev/ttyPlotter
ExecStart=/usr/bin/socat -d -d pty,raw,echo=0,link=/dev/ttyPlotter,user=tablet,group=dialout,mode=660 tcp:127.0.0.1:8888
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

### B.4. Serwer kamery

```bash
sudo install -m 755 -o tablet -g tablet scripts/webcam_stream.py /home/tablet/webcam_stream.py
```

Zapisz `/etc/systemd/system/octoprint-webcam.service`:

```ini
[Unit]
Description=MJPEG webcam stream for OctoPrint (/dev/video0)
After=multi-user.target

[Service]
Type=simple
User=tablet
Environment=WEBCAM_DEVICE=0
Environment=WEBCAM_PORT=8080
ExecStart=/usr/bin/python3 /home/tablet/webcam_stream.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

### B.5. Usługa OctoPrint

Zapisz `/etc/systemd/system/octoprint.service`:

```ini
[Unit]
Description=OctoPrint Server
After=network.target octoprint-serial-bridge.service
Wants=octoprint-serial-bridge.service

[Service]
Type=simple
User=tablet
WorkingDirectory=/home/tablet
ExecStart=/home/printer/OctoPrint/venv/bin/octoprint serve
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### B.6. Konfiguracja OctoPrint

```bash
sudo systemctl stop octoprint      # KONIECZNE — inaczej zmiany zostaną nadpisane
```

W `/home/tablet/.octoprint/config.yaml` ustaw:

```yaml
serial:
  additionalPorts:
    - /dev/ttyPlotter
  port: /dev/ttyPlotter
  baudrate: 115200
  autoconnect: true
plugins:
  classicwebcam:
    stream: http://<IP-TABLETU>:8080/stream.mjpg
    snapshot: http://<IP-TABLETU>:8080/snapshot.jpg
```

### B.7. Włączenie

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now octoprint-serial-bridge octoprint-webcam octoprint
```

### B.8. Skrót na pulpicie (opcjonalnie)

```bash
sudo install -m 755 -o tablet -g tablet scripts/octoprint-control.sh /home/tablet/octoprint-control.sh
```

Zapisz `/home/tablet/Desktop/OctoPrint.desktop`:

```ini
[Desktop Entry]
Version=1.0
Type=Application
Name=OctoPrint Server
Comment=Kontrola usługi OctoPrint (systemd): start/stop/restart/autostart
Exec=bash /home/tablet/octoprint-control.sh
Icon=utilities-terminal
Terminal=true
Categories=Development;Engineering;
```

```bash
sudo chmod 755 /home/tablet/Desktop/OctoPrint.desktop
sudo chown tablet:tablet /home/tablet/Desktop/OctoPrint.desktop
```

---

## Konfiguracja po instalacji

### Autostart OctoPrint

Domyślnie usługa startuje z systemem. Wyłączenie (usługa dalej działa, tylko nie wstaje po reboocie):

```bash
sudo systemctl disable octoprint
sudo systemctl enable octoprint     # z powrotem
```

Albo od razu przy instalacji:

```bash
sudo ENABLE_OCTOPRINT_AUTOSTART=0 ./install.sh
```

### Zmiana parametrów kamery

```bash
sudo systemctl edit octoprint-webcam
```

```ini
[Service]
Environment=WEBCAM_WIDTH=1920
Environment=WEBCAM_HEIGHT=1080
Environment=WEBCAM_QUALITY=90
```

```bash
sudo systemctl restart octoprint-webcam
```

### Kamera na innym urządzeniu

```bash
sudo WEBCAM_DEVICE_INDEX=1 ./install.sh
```

### Bez kamery

```bash
sudo WEBCAM_ENABLE=0 ./install.sh
```

### Inny port GRBL

```bash
sudo GRBL_TCP_PORT=9999 ./install.sh
```

---

## Weryfikacja po instalacji

```bash
# usługi
systemctl is-active octoprint octoprint-serial-bridge octoprint-webcam

# port szeregowy istnieje
ls -l /dev/ttyPlotter

# kamera odpowiada
wget -qO- http://127.0.0.1:8080/snapshot.jpg | wc -c

# panel odpowiada
wget -qO- http://127.0.0.1:5000/api/version
```

Oczekiwane: trzy razy `active`, istniejący symlink do `/dev/pts/N`, niezerowy rozmiar JPEG, JSON z wersją OctoPrint.

---

## Odinstalowanie

```bash
sudo ./uninstall.sh
```

Usuwa trzy usługi systemd, skrypt kamery i skrót z pulpitu. **Nie rusza** instalacji OctoPrint, venv, profilu ani pluginu — jeśli chcesz usunąć plugin:

```bash
sudo -u printer /home/printer/OctoPrint/venv/bin/python -m pip uninstall Better-Grbl-Support
```
