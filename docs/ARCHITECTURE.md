# Architektura

## Przepływ danych

```
                    TABLET (RK3128, Ubuntu 22.04 armhf)
  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                      │
  │   przeglądarka klienta                                               │
  │        │  :5000                                                      │
  │        ▼                                                             │
  │   ┌─────────────────┐                                                │
  │   │ octoprint       │  user: tablet                                  │
  │   │ .service        │  venv: /home/printer/OctoPrint/venv            │
  │   └────────┬────────┘                                                │
  │            │  otwiera /dev/ttyPlotter  (plik-urządzenie PTY)          │
  │            ▼                                                         │
  │   ┌─────────────────┐                                                │
  │   │ octoprint-      │  socat: PTY  ⇄  TCP 127.0.0.1:8888             │
  │   │ serial-bridge   │                                                │
  │   └────────┬────────┘                                                │
  │            │                                                         │
  │            │  :8888  (serial-over-tcp — usługa dostarczona z systemem)│
  │            ▼                                                         │
  │      /dev/ttyS1  ──UART──►  kontroler GRBL  ──►  ploter / drag knife │
  │                                                                      │
  │   ┌─────────────────┐        ┌──────────────────────┐                │
  │   │ octoprint-      │  :8080 │ classicwebcam (UI)   │                │
  │   │ webcam.service  │◄───────┤ <img src=:8080/...>  │                │
  │   └────────┬────────┘        └──────────────────────┘                │
  │            │  cv2.VideoCapture                                       │
  │            ▼                                                         │
  │      /dev/video0  (kamera USB, UVC)                                  │
  └──────────────────────────────────────────────────────────────────────┘
```

## Trzy decyzje projektowe i ich uzasadnienie

### 1. Dlaczego `socat` z PTY, a nie `socket://` bezpośrednio w OctoPrincie

OctoPrint przyjmuje port połączenia, ale **waliduje go wobec listy realnie istniejących portów** — `serialList()` bierze porty wykryte przez pyserial i dodatkowo rozwija wpisy z `serial.additionalPorts` przez `glob()` po systemie plików.

Wpis typu `socket://127.0.0.1:8888` nie jest plikiem, więc `glob()` nic nie zwraca i port **wypada z listy**. Efekt:

```json
POST /api/connection {"command":"connect","port":"socket://127.0.0.1:8888", ...}
→ 400 {"error": "port is invalid"}
```

Co gorsza, pyserial *umie* obsłużyć taki URL (przez `serial_for_url`) — i ręczny test z Pythona działa bez problemu, co potrafi długo mylić:

```python
serial.serial_for_url('socket://127.0.0.1:8888', baudrate=115200)   # DZIAŁA
```

`socat` rozwiązuje to elegancko: tworzy **prawdziwy plik-urządzenie** (PTY), który `glob()` znajduje jak każdy inny port szeregowy. OctoPrint widzi normalny port i łączy się bez oporów. Dodatkowo `link=` daje stabilną nazwę (`/dev/ttyPlotter`) zamiast losowego `/dev/pts/N`.

### 2. Dlaczego jedna usługa systemd na komponent, a nie skrypt startowy

Każdy element ma inne wymagania i inne tryby awarii:

| Komponent | Zależność | Restart |
|---|---|---|
| `octoprint-serial-bridge` | musi wstać **przed** OctoPrintem | `on-failure` (utrata TCP GRBL) |
| `octoprint` | `Wants=` most | `on-failure` |
| `octoprint-webcam` | niezależny od pozostałych | `on-failure` (odpięcie kamery) |

Rozdzielenie pozwala restartować jeden element bez przewracania reszty — np. kamera po przepięciu USB wstaje sama, nie ruszając drukowania.

### 3. Dlaczego własny serwer MJPEG na OpenCV, a nie `mjpg-streamer`

Standardem dla OctoPrint jest `mjpg-streamer`, ale:

- nie był zainstalowany, a instalacja przez `apt` wymaga dostępu do sieci i praw root w momencie wdrożenia,
- `python3-opencv` był już obecny systemowo (typowe na obrazach z GUI),
- potrzeby są minimalne: jedna kamera, dwie ścieżki HTTP.

Serwer w `scripts/webcam_stream.py` to ~90 linii na bibliotece standardowej (`http.server`) plus OpenCV. Serwuje dwa endpointy:

- `/stream.mjpg` — `multipart/x-mixed-replace` (format, który przeglądarki renderują natywnie w `<img>`),
- `/snapshot.jpg` — pojedyncza klatka.

Kluczowe szczegóły implementacji:

- **jeden wątek zbierający** klatki (`grabber`) — wielu klientów nie otwiera kamery po raz drugi (to typowa przyczyna „drugi podgląd psuje pierwszy”),
- **`ThreadingHTTPServer`** — równoległe snapshoty i stream nie blokują się nawzajem,
- **`os._exit(1)` po serii nieudanych odczytów** — pozwala `Restart=on-failure` podnieść usługę po wypięciu kamery, zamiast wisieć i serwować pustkę.

## Podział użytkowników

W typowym wdrożeniu na tym tablecie są **dwa konta** i to jest źródłem większości problemów z uprawnieniami:

| Konto | Rola | Dlaczego tak |
|---|---|---|
| `printer` | właściciel venv OctoPrint | instalacja OctoPrint została zrobiona na tym koncie |
| `tablet` | sesja graficzna, serwer OctoPrint, kamera | to konto ma auto-login w `sddm` i pulpit |

Usługa działa jako `tablet`, a pakiety należą do `printer` — stąd:

- **odczyt**: przy `700` na katalogach pakietów `tablet` dostaje `ImportError` (mimo że jest w grupie `printer`, grupa nie ma `rwx`),
- **zapis**: przy `755` na `site-packages` Plugin Manager nie może instalować pluginów i zgłasza błąd o pip.

Instalator rozwiązuje oba naraz, ustawiając **grupę venv na grupę główną usera usługi** i nadając `g+rwX` — bez zmiany właściciela, więc venv może pozostać współdzielony:

```bash
chown -R "${OCTOPRINT_USER}:$(id -gn "${DESKTOP_USER}")" "${OCTOPRINT_VENV}"
chmod -R g+rwX "${OCTOPRINT_VENV}"
```

## Kolejność operacji w instalatorze

Kolejność nie jest przypadkowa:

1. **uprawnienia venv** — zanim cokolwiek uruchomimy jako user usługi,
2. **plugin** — wymaga zapisu do venv, więc po naprawie uprawnień,
3. **szablony usług** → `/etc/systemd/system/`,
4. **`systemctl daemon-reload`** — musi być po zapisaniu plików, przed `enable`,
5. **`stop octoprint`** — **przed** edycją `config.yaml` (patrz niżej),
6. **edycja `config.yaml`**,
7. **`enable --now`** usług,
8. **skróty na pulpicie**.

### Dlaczego `stop` przed edycją `config.yaml`

OctoPrint trzyma ustawienia w pamięci i **zapisuje je do `config.yaml` przy zmianie oraz przy zamykaniu**. Edycja pliku na działającym procesie kończy się więc nadpisaniem zmian przy najbliższym restarcie — objaw jest mylący, bo plik przez chwilę wygląda poprawnie, a po restarcie wraca stara wartość. Instalator zatrzymuje usługę, edytuje plik i dopiero potem startuje.

## Dlaczego tylko jeden klient na porcie GRBL

Most `serial-over-tcp` na porcie 8888 działa zwykle w trybie `socat ... fork,reuseaddr`, gdzie **każde nowe połączenie TCP dostaje świeży proces-dziecko**, a każde dziecko **niezależnie otwiera ten sam port szeregowy** (`/dev/ttyS1`).

Przy dwóch równoczesnych klientach (np. OctoPrint + otwarte bCNC) oba procesy czytają z tego samego urządzenia i **odpowiedzi GRBL rozjeżdżają się między nich** — w praktyce widać poszatkowane, przeplatane bajty:

```
b"000,-297.208,0.000|Bf:1n:YZ|Ov:100,100,GrblHAL 1.1f ['$ help]\r\n<Idle|MP.208,0.000|Bf:100|Pn00|A:|TLR:0>\r\n"
```

Dlatego:

- przed uruchomieniem mostu zamknij bCNC / Candle / inne sendery,
- przy diagnozie „nie łączy się” **najpierw** sprawdź, kto jeszcze siedzi na porcie:

```bash
ss -tnp | grep 8888
pgrep -af socat
```

## Idempotencja

Instalator można uruchamiać wielokrotnie:

- `chown`/`chmod` — operacje powtarzalne,
- instalacja pluginu — sprawdzana przez `pip show`,
- szablony — nadpisywane w całości,
- `config.yaml` — ustawiane konkretne klucze, reszta profilu nietknięta,
- `enable --now` — na już włączonej usłudze to no-op.
