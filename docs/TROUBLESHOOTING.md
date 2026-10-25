# Diagnostyka

Wszystkie przypadki poniżej wystąpiły realnie przy wdrażaniu tego setupu. Kolejność: od najczęstszych.

---

## 1. OctoPrint nie startuje: `ImportError: cannot import name 'main' from 'octoprint'`

```
Traceback (most recent call last):
  File ".../venv/bin/octoprint", line 3, in <module>
    from octoprint import main
ImportError: cannot import name 'main' from 'octoprint' (unknown location)
```

**Objaw towarzyszący:** Python nie rzuca „No module named”, tylko `unknown location` — czyli *widzi* katalog pakietu, ale nie może go przeczytać.

**Przyczyna:** katalogi pakietu w venv mają prawa `700` i należą do innego użytkownika niż ten, który uruchamia usługę. Typowo: venv należy do `printer`, a serwer startuje jako `tablet`. Sam fakt bycia w grupie `printer` nie pomaga — przy `700` grupa nie ma żadnych uprawnień.

Skąd bierze się `700`: narzędzia aktualizujące OctoPrint często ustawiają `umask 077` (żeby backupy nie były czytelne dla innych), ale obejmuje to też pakiety instalowane przez `pip` w trakcie aktualizacji.

**Sprawdzenie:**

```bash
ls -ld <venv>/lib/python*/site-packages/octoprint
# drwx------ = 700 → to jest problem
```

**Naprawa:**

```bash
sudo chmod -R a+rX <venv>
```

**Zapobieganie:** `install.sh` ustawia grupę venv na grupę usera usługi i nadaje `g+rwX`, więc problem nie wraca. **Uwaga:** jeśli aktualizujesz OctoPrint osobnym narzędziem, po aktualizacji uruchom instalator ponownie — albo ręcznie powtórz `chmod`.

---

## 2. Plugin Manager: „pip command could not be found or does not work correctly”

```
The pip command could not be found or does not work correctly for this
installation of OctoPrint - please consult the log file for details...
No installation and uninstallation of plugin packages is possible while
pip is unavailable.
```

**Przyczyna:** user, jako który działa serwer, **nie ma prawa zapisu** do `site-packages`. OctoPrint sam wykrywa brak zapisu i celowo blokuje pip — żeby nie dawać wrażenia, że instalacja pluginu się powiedzie.

Log pokazuje to wprost:

```
octoprint.util.pip - INFO - pip installs to <venv>/lib/python3.10/site-packages (writable -> no)
octoprint.util.pip - INFO - ==> pip ok -> NO!
octoprint.util.pip - ERROR - Cannot use this pip install, can't write to the install dir
```

**Naprawa:**

```bash
sudo chmod -R g+rwX <venv>
```

Jeśli user usługi nie jest w grupie właściciela venv, najpierw:

```bash
sudo chown -R <owner>:$(id -gn <service_user>) <venv>
```

**Weryfikacja — zapis z konta usera usługi:**

```bash
sudo -u <service_user> touch <venv>/lib/python3.10/site-packages/.test && echo OK
```

**Uwaga:** objaw bywa mylący, bo `python -m pip --version` działa poprawnie — problem nie jest z pip, tylko z prawem zapisu.

---

## 3. Instalacja pluginu: „Could not import OctoPrint's setuptools”

```
× Getting requirements to build wheel did not run successfully.
╰─> Could not import OctoPrint's setuptools, are you sure you are running
    that under the same python installation that OctoPrint is installed under?
```

**Przyczyna:** pip domyślnie buduje paczkę w **izolowanym** środowisku (PEP 517), które nie widzi `octoprint_setuptools` zainstalowanego w venv OctoPrint.

**Naprawa:**

```bash
<venv>/bin/python -m pip install --no-build-isolation <url-paczki>
```

Flaga `--no-build-isolation` jest **wymagana** przy instalacji pluginów OctoPrint z repo/źródeł. `install.sh` używa jej domyślnie.

---

## 4. Połączenie wisi na „Connecting” / odpowiedzi GRBL są poszatkowane

**Objaw:** stan w UI nigdy nie dochodzi do `Operational`, a przy ręcznym teście widać przeplatane bajty z dwóch różnych odpowiedzi:

```
b"000,-297.208,0.000|Bf:1n:YZ|Ov:100,100,GrblHAL 1.1f ['$ help]\r\n<Idle|MP.208,0.000|Bf:100|Pn00|A:|TLR:0>\r\n"
```

**Przyczyna:** **dwóch klientów jednocześnie** na porcie GRBL. `serial-over-tcp` działa zwykle jako `socat ... fork,reuseaddr` — każde nowe połączenie TCP dostaje własny proces-dziecko, a każde dziecko niezależnie otwiera ten sam port szeregowy. Odpowiedzi rozjeżdżają się między procesy.

Typowe źródła drugiego klienta:

- otwarte **bCNC** lub **Candle** (nawet zminimalizowane — wystarczy, że trzyma połączenie),
- **porzucony most `socat`** z wcześniejszych prób (np. testowy `/tmp/ttyPlotter`, którego nikt nie zabił),
- ręczny test z Pythona, który nie zamknął gniazda.

**Diagnoza:**

```bash
ss -tnp | grep 8888     # ile połączeń i czyje
pgrep -af socat         # ile procesów mostu
```

**Naprawa:** zostaw dokładnie **jednego** klienta.

```bash
# zamknij bCNC/Candle, potem ubij zbędne mosty:
kill <PID_klienta>
sudo systemctl restart octoprint-serial-bridge   # świeży PTY
sudo systemctl restart octoprint
```

**Weryfikacja czystego łącza** (jeden klient, oczekiwana pojedyncza odpowiedź):

```bash
sudo -u <service_user> <venv>/bin/python - <<'EOF'
import serial, time
s = serial.Serial('/dev/ttyPlotter', 115200, timeout=2)
s.write(b'?')
time.sleep(1)
print(s.read(200))
EOF
# b'<Idle|MPos:-215.000,-297.208,0.000|Bf:100,1024|FS:0,0|Pn:YZ>\r\n'
```

**Zasada:** most i bCNC wzajemnie się wykluczają. Nie używaj obu naraz.

---

## 5. `400 {"error": "port is invalid"}` przy próbie połączenia

**Przyczyna:** podany port nie występuje na liście, którą OctoPrint uważa za istniejącą. Dotyczy w szczególności URL-i (`socket://host:port`) — OctoPrint rozwija `serial.additionalPorts` przez `glob()` po systemie plików, a URL nie jest plikiem, więc zawsze wypada z listy. Mimo że pyserial sam taki URL obsługuje.

**Sprawdzenie, co OctoPrint realnie widzi:**

```bash
curl -H "X-Api-Key: <klucz>" http://127.0.0.1:5000/api/connection
# sekcja "options" → "ports": [...]
```

**Naprawa:** użyj mostu `socat` z PTY (tak robi `install.sh`) — daje prawdziwy plik-urządzenie, który trafia na listę:

```bash
socat -d -d pty,raw,echo=0,link=/dev/ttyPlotter tcp:127.0.0.1:8888
```

---

## 6. Logowanie zwraca `403` mimo poprawnych danych

**Objaw:** hasło na pewno dobre (ustawione CLI), a `POST /api/login` zwraca:

```json
{"error": "You don't have the permission to access the requested resource..."}
```

W logach: `403 POST /api/login`.

**Przyczyna:** **wbudowany rate limiter OctoPrint** chroniący `/api/login` przed brute-force. Po serii nieudanych prób blokuje endpoint **niezależnie od poprawności hasła**. Łatwo to zdiagnozować błędnie jako złe hasło.

**Naprawa:**

```bash
sudo systemctl restart octoprint
```

Limiter trzyma stan w pamięci procesu, więc restart go zeruje.

**Ustawienie/reset hasła z CLI** (pewniejsze niż API, działa też przy zablokowanym loginie):

```bash
sudo -u <service_user> <venv>/bin/octoprint user password <login> --password '<hasło>'
```

**Zapobieganie:** nie testuj hasła wielokrotnie pod rząd — po 2–3 nieudanych próbach zrób restart.

---

## 7. Podgląd kamery pusty zdalnie, ale działa lokalnie na tablecie

**Przyczyna:** URL streamu w `config.yaml` ustawiony na `127.0.0.1`. Ten adres trafia do `<img src>` **w przeglądarce klienta**, więc przeglądarka szuka kamery na własnej maszynie.

**Sprawdzenie:**

```bash
grep -A3 classicwebcam <basedir>/config.yaml
```

**Naprawa** — ustaw adres osiągalny z sieci klienta:

```bash
sudo ./install.sh WEBCAM_PUBLIC_HOST=192.168.1.50
```

albo ręcznie w `config.yaml` (przy **zatrzymanym** OctoPrincie — patrz punkt 8):

```yaml
plugins:
  classicwebcam:
    stream: http://192.168.1.50:8080/stream.mjpg
    snapshot: http://192.168.1.50:8080/snapshot.jpg
```

**Test samego serwera kamery** (bez OctoPrint):

```bash
wget -qO- http://127.0.0.1:8080/snapshot.jpg | wc -c    # > 0 = działa
```

---

## 8. Zmiany w `config.yaml` „nie działają” / wracają po restarcie

**Przyczyna:** OctoPrint trzyma ustawienia w pamięci i **zapisuje je przy zmianie oraz przy zamykaniu**. Edycja pliku na działającym procesie zostaje nadpisana.

**Naprawa:** zawsze zatrzymaj usługę przed edycją:

```bash
sudo systemctl stop octoprint
sudo nano <basedir>/config.yaml
sudo systemctl start octoprint
```

`install.sh` robi to w tej właśnie kolejności.

---

## 9. Kamera: proces żyje, ale obraz się nie odświeża

**Przyczyna:** kamera została odpięta/przepięta, a proces dalej działa i serwuje ostatnią klatkę (albo pustkę).

**Naprawa wbudowana:** `webcam_stream.py` kończy się z błędem po serii nieudanych odczytów (`WEBCAM_MAX_FAILURES`, domyślnie 50), a `Restart=on-failure` podnosi usługę. Sprawdź:

```bash
systemctl status octoprint-webcam
journalctl -u octoprint-webcam -n 30 --no-pager
```

Ręcznie:

```bash
sudo systemctl restart octoprint-webcam
```

**Uwaga:** jeśli kamera nie jest wykrywana wcale, sprawdź `ls -la /dev/video*` i czy indeks się zgadza (`WEBCAM_DEVICE_INDEX`).

---

## 10. Ostrzeżenie w UI: „Python version nearing its end of life”

To **nie jest błąd** — OctoPrint 1.11+ ma wbudowany health check środowiska i przypomina o końcu wsparcia wersji Pythona. Nie blokuje żadnej funkcji.

Na Ubuntu 22.04 armhf migracja na nowszy Python to poważna operacja (kompilacja ze źródeł lub reinstalacja systemu). **`ppa:deadsnakes` nie wspiera architektur ARM** — próba instalacji nowszego Pythona tą drogą nie powiedzie się.

Komunikat pojawia się okresowo (per przeglądarka). Można go zignorować, dopóki nie planujesz aktualizacji systemu.

---

## 11. `sudo` w skryptach z `set -e` cicho przerywa działanie

Dotyczy autorów modyfikujących `install.sh`:

```bash
set -e
[[ "$X" == "1" ]] && cos_tam    # gdy X != 1, lista zwraca 1
```

Zapis `[[ ... ]] && cmd` na końcu bloku potrafi przerwać skrypt, gdy warunek nie zajdzie. Zamień na jawny blok:

```bash
if [[ "$X" == "1" ]]; then
    cos_tam
fi
```

---

## Zbieranie informacji do zgłoszenia

```bash
{
  echo "--- wersje ---"
  uname -a
  cat /etc/os-release | head -3
  <venv>/bin/octoprint --version
  echo "--- usługi ---"
  systemctl status octoprint octoprint-serial-bridge octoprint-webcam --no-pager
  echo "--- porty ---"
  ss -tlnp | grep -E '5000|8080|8888'
  echo "--- klienci GRBL ---"
  ss -tnp | grep 8888
  pgrep -af socat
  echo "--- logi ---"
  journalctl -u octoprint -n 50 --no-pager
} > diagnoza.txt 2>&1
```

**Przed publikacją usuń z `diagnoza.txt` klucze API i dane logowania** (`api.key`, `secretKey` w `config.yaml`).
