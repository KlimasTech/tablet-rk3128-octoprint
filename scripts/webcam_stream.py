#!/usr/bin/env python3
"""Prosty serwer MJPEG + snapshot dla OctoPrint classicwebcam.

Zastępuje mjpg-streamer gdy nie jest zainstalowany (np. brak sudo/apt) —
używa python3-opencv (cv2), które na wielu dystrybucjach ARM jest już
preinstalowane systemowo.

Zmienne środowiskowe:
  WEBCAM_DEVICE   - indeks /dev/videoN (domyślnie 0)
  WEBCAM_PORT     - port HTTP (domyślnie 8080)
  WEBCAM_WIDTH    - szerokość klatki (domyślnie 1280)
  WEBCAM_HEIGHT   - wysokość klatki (domyślnie 720)
  WEBCAM_QUALITY  - jakość JPEG 1-100 (domyślnie 80)
"""
import os
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2

DEVICE = int(os.environ.get("WEBCAM_DEVICE", "0"))
PORT = int(os.environ.get("WEBCAM_PORT", "8080"))
WIDTH = int(os.environ.get("WEBCAM_WIDTH", "1280"))
HEIGHT = int(os.environ.get("WEBCAM_HEIGHT", "720"))
QUALITY = int(os.environ.get("WEBCAM_QUALITY", "80"))
# Po tylu nieudanych odczytach z rzędu kończymy proces z błędem, żeby
# systemd (Restart=on-failure) podniósł usługę od nowa — inaczej po
# wypięciu/przepięciu kamery proces wisiałby i serwował pustkę.
MAX_CONSECUTIVE_FAILURES = int(os.environ.get("WEBCAM_MAX_FAILURES", "50"))

cap = cv2.VideoCapture(DEVICE)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)

if not cap.isOpened():
    print(f"BLAD: nie moge otworzyc /dev/video{DEVICE}", file=sys.stderr, flush=True)
    sys.exit(1)

lock = threading.Lock()
latest_frame = [None]


def grabber():
    failures = 0
    while True:
        ok, frame = cap.read()
        if ok:
            failures = 0
            ok2, jpg = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), QUALITY])
            if ok2:
                with lock:
                    latest_frame[0] = jpg.tobytes()
        else:
            failures += 1
            if failures >= MAX_CONSECUTIVE_FAILURES:
                print("BLAD: kamera przestala zwracac klatki — restart uslugi",
                      file=sys.stderr, flush=True)
                os._exit(1)
        time.sleep(0.05)


threading.Thread(target=grabber, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/snapshot"):
            with lock:
                data = latest_frame[0]
            if data is None:
                self.send_response(503)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path.startswith("/stream"):
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.end_headers()
            try:
                while True:
                    with lock:
                        data = latest_frame[0]
                    if data is not None:
                        self.wfile.write(b"--frame\r\n")
                        self.wfile.write(b"Content-Type: image/jpeg\r\n")
                        self.wfile.write(("Content-Length: %d\r\n\r\n" % len(data)).encode())
                        self.wfile.write(data)
                        self.wfile.write(b"\r\n")
                    time.sleep(0.1)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()
