# tablet-rk3128-octoprint

Automatyzacja wdrożenia **OctoPrint jako kontrolera plotera/CNC po GRBL** na przemysłowym tablecie ARM (RK3128, Ubuntu 22.04 armhf) — z mostem szeregowym do portu GRBL wystawionego po TCP, obsługą kamery USB i usługami systemd, które przetrwają restart.

Projekt powstał przy okazji uruchamiania 7-calowego panelu dotykowego z projektu [plotter-doctor/industrial_tablet](https://github.com/plotter-doctor/industrial_tablet) jako sterownika plotera z nożem ciągnionym (drag knife), wpiętego w istniejący OctoPrint zamiast bCNC/Candle.

## Co to robi

Tablet ma już zainstalowany OctoPrint (uruchamiany ręcznie z pulpitu), a ploter jest dostępny jako **GRBL na porcie szeregowym wystawionym przez TCP** (usługa `serial-over-tcp` na porcie 8888). Instalator domyka tę instalację:

1. **Wpina OctoPrint w GRBL** — przez wirtualny port szeregowy `socat` (`/dev/ttyPlotter`) → most TCP do GRBL. Bezpośredni `socket://` nie działa, bo OctoPrint odrzuca URL-e jako porty (szczegóły: [ARCHITECTURE](docs/ARCHITECTURE.md)).
2. **Dodaje plugin `bettergrblsupport`** — panel jogowania, obsługa `M3/M4/M5`, reset alarmu GRBL, ukrycie UI temperatury/ekstrudera (bezużytecznego dla plotera).
3. **Stawia serwer MJPEG dla kamery USB** — własny, oparty na OpenCV (nie wymaga `mjpg-streamer` ani apt), podpinany do wbudowanego pluginu `classicwebcam`.
4. **Opakowuje wszystko w usługi systemd** — `octoprint`, `octoprint-serial-bridge`, `octoprint-webcam`, żeby działało po reboocie.
5. **Naprawia uprawnienia venv** — tak, żeby user usługi mógł czytać pakiety *i* instalować pluginy z UI.
6. **Podmienia skrót na pulpicie** — z „uruchom serwer” na panel kontrolny usługi (start/stop/restart/autostart).

## Wymagania

| Element | Wymaganie |
|---|---|
| System | Ubuntu 22.04 (lub pokrewny) armhf/arm64, systemd |
| OctoPrint | istniejąca instalacja w venv (np. `/home/printer/OctoPrint/venv`) |
| GRBL | dostępny po TCP (np. `serial-over-tcp` na `127.0.0.1:8888`) |
| Pakiety | `socat`, `systemctl` (systemd), `runuser` (util-linux) |
| Kamera (opcjonalnie) | `python3-opencv` + urządzenie `/dev/videoN` |
| Uprawnienia | `root` (`sudo`) |

## Szybki start

```bash
git clone https://github.com/KlimasTech/tablet-rk3128-octoprint.git
cd tablet-rk3128-octoprint
sudo ./install.sh --help     # opcjonalnie: przegląd zmiennych
sudo ./install.sh
```

Dla instalacji innej niż domyślna:

```bash
sudo OCTOPRINT_VENV=/home/pi/oprint/venv \
     OCTOPRINT_USER=pi \
     DESKTOP_USER=pi \
     GRBL_TCP_PORT=8888 \
     ./install.sh
```

Po zakończeniu panel jest pod `http://<IP-tabletu>:5000`. Skrypt jest **idempotentny** — można go uruchamiać wielokrotnie.

## Co instaluje

| Usługa | Plik | Rola |
|---|---|---|
| `octoprint.service` | `/etc/systemd/system/octoprint.service` | serwer OctoPrint (port 5000) |
| `octoprint-serial-bridge.service` | `/etc/systemd/system/octoprint-serial-bridge.service` | `socat` PTY `/dev/ttyPlotter` ↔ TCP GRBL |
| `octoprint-webcam.service` | `/etc/systemd/system/octoprint-webcam.service` | serwer MJPEG z kamery (port 8080) |

Dodatkowo:
- `/home/<DESKTOP_USER>/webcam_stream.py` — serwer kamery
- `/home/<DESKTOP_USER>/octoprint-control.sh` + skrót `Desktop/OctoPrint.desktop`
- plugin `bettergrblsupport` w venv OctoPrint
- wpisy `serial.*` i `plugins.classicwebcam.*` w `config.yaml`

## Konfiguracja

Wszystkie zmienne są opcjonalne i nadpisywalne z linii poleceń (`sudo ZMIENNA=wartość ./install.sh`). Pełny opis: `./install.sh --help`.

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
| `OCTOPRINT_VENV` | `/home/printer/OctoPrint/venv` | venv OctoPrint |
| `OCTOPRINT_USER` | `printer` | właściciel venv / user pip |
| `DESKTOP_USER` | `tablet` | user, jako który działa serwer i kamera |
| `OCTOPRINT_BASEDIR` | `/home/<DESKTOP_USER>/.octoprint` | profil OctoPrint |
| `SERIAL_LINK` | `/dev/ttyPlotter` | wirtualny port szeregowy |
| `GRBL_TCP_HOST` / `GRBL_TCP_PORT` | `127.0.0.1` / `8888` | most TCP z GRBL |
| `SERIAL_BAUDRATE` | `115200` | prędkość portu |
| `PRINTER_PROFILE` | `_bgs` | profil drukarki (bettergrblsupport) |
| `WEBCAM_ENABLE` | `1` | `0` = pomiń kamerę |
| `WEBCAM_DEVICE_INDEX` | `0` | `/dev/videoN` |
| `WEBCAM_PORT` | `8080` | port serwera MJPEG |
| `WEBCAM_PUBLIC_HOST` | auto (IP LAN) | adres kamery **widziany z przeglądarki** |
| `INSTALL_DESKTOP_SHORTCUTS` | `1` | `0` = bez skrótów |
| `SKIP_PLUGIN_INSTALL` | `0` | `1` = nie instaluj pluginu |
| `FIX_VENV_PERMISSIONS` | `1` | `0` = nie ruszaj uprawnień venv |
| `ENABLE_OCTOPRINT_AUTOSTART` | `1` | `0` = usługa nie startuje z systemem |

> **`WEBCAM_PUBLIC_HOST`** — to nie jest to samo co adres, na którym nasłuchuje serwer kamery. Wpis idzie do `config.yaml` i trafia do `<img src>` w przeglądarce klienta, więc **musi być adresem osiągalnym z jego sieci**. Ustawienie tu `127.0.0.1` (typowy błąd) sprawia, że podgląd działa tylko na samym tablecie, a zdalnie jest pusty.

## Zarządzanie usługami

```bash
# stan
systemctl status octoprint octoprint-serial-bridge octoprint-webcam

# sterowanie serwerem
sudo systemctl start octoprint
sudo systemctl stop octoprint
sudo systemctl restart octoprint

# autostart przy boocie
sudo systemctl enable octoprint     # włącz
sudo systemctl disable octoprint    # wyłącz (usługa dalej działa teraz)

# logi
journalctl -u octoprint -n 50 --no-pager
journalctl -u octoprint-serial-bridge -n 50 --no-pager
```

Na pulpicie tabletu jest też skrót **OctoPrint Server** (`octoprint-control.sh`) — menu start/stop/restart/autostart, każda operacja administracyjna prosi o hasło `sudo`.

## Weryfikacja

```bash
# 1. czy most utworzył port
ls -l /dev/ttyPlotter

# 2. czy GRBL odpowiada (bezpośrednio, przez most)
sudo -u <DESKTOP_USER> /home/<OCTOPRINT_USER>/OctoPrint/venv/bin/python - <<'EOF'
import serial, time
s = serial.Serial('/dev/ttyPlotter', 115200, timeout=2)
s.write(b'?')
time.sleep(1)
print(s.read(200))
EOF
# oczekiwane: b'<Idle|MPos:...|FS:0,0|Pn:...>'

# 3. czy kamera odpowiada
wget -qO- http://127.0.0.1:8080/snapshot.jpg | wc -c   # > 0
```

W UI OctoPrint: **Connection** → port `/dev/ttyPlotter`, profil *Grbl Default Machine*, stan **Operational**.

## Typowe problemy

Najkrótsza diagnoza — [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). Najczęstsze:

| Objaw | Przyczyna | Szybka naprawa |
|---|---|---|
| `ImportError: cannot import name 'main' from 'octoprint'` | venv ma prawa `700`, user usługi nie czyta pakietów | `sudo chmod -R a+rX <venv>` |
| Plugin Manager: „pip could not be found…” | user usługi nie ma prawa **zapisu** do `site-packages` | `sudo chmod -R g+rwX <venv>` |
| `pip`: „Could not import OctoPrint's setuptools” | pip w izolowanym środowisku budowania | `pip install --no-build-isolation` |
| Stan wisi na „Connecting” | dwóch klientów na porcie GRBL jednocześnie | rozłącz bCNC/Candle, zostaw jednego klienta |
| `port is invalid` przy `socket://…` | OctoPrint nie przyjmuje URL-i jako portów | użyj mostu `socat` (ten instalator) |
| Logowanie zwraca `403` mimo dobrego hasła | rate limiter po nieudanych próbach | `sudo systemctl restart octoprint` |
| Podgląd kamery pusty zdalnie, działa lokalnie | `127.0.0.1` w URL streamu | ustaw `WEBCAM_PUBLIC_HOST` na IP tabletu |

## Odinstalowanie

```bash
sudo ./uninstall.sh            # usuwa usługi i skrót, zostawia OctoPrint i venv
```

## Struktura repozytorium

```
install.sh                              # instalator (idempotentny)
uninstall.sh                            # cofnięcie zmian instalatora
scripts/
  webcam_stream.py                      # serwer MJPEG/snapshot (OpenCV)
  octoprint-control.sh                  # panel kontrolny usługi na pulpicie
systemd/
  octoprint.service.template            # szablony z placeholderami __ZMIENNA__
  octoprint-serial-bridge.service.template
  octoprint-webcam.service.template
docs/
  INSTALL.md                            # instalacja krok po kroku + instalacja ręczna
  ARCHITECTURE.md                        # jak to działa i dlaczego tak
  TROUBLESHOOTING.md                     # diagnoza realnych problemów
```

## Licencja

MIT — patrz [LICENSE](LICENSE).
