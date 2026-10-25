#!/bin/bash
# Prosty panel kontrolny dla usługi octoprint.service, wywoływany ze skrótu
# na pulpicie. Zastępuje ręczne "octoprint serve" (konfliktowałoby z portem
# zajętym przez systemd), zamiast tego steruje tą samą usługą.
set -u

echo "=== OctoPrint Server — kontrola ==="
echo
systemctl status octoprint --no-pager -l 2>&1 | head -5
echo
echo "1) Start"
echo "2) Stop"
echo "3) Restart"
echo "4) Status (szczegoly)"
echo "5) Autostart WLACZ (enable)"
echo "6) Autostart WYLACZ (disable)"
echo "0) Wyjdz"
echo
read -rp "Wybierz opcje: " opt
case "$opt" in
  1) sudo systemctl start octoprint ;;
  2) sudo systemctl stop octoprint ;;
  3) sudo systemctl restart octoprint ;;
  4) systemctl status octoprint --no-pager -l ;;
  5) sudo systemctl enable octoprint ;;
  6) sudo systemctl disable octoprint ;;
  0) exit 0 ;;
  *) echo "Nieznana opcja" ;;
esac

echo
printf "Gotowe. Status teraz:\n"
systemctl is-enabled octoprint 2>&1
systemctl is-active octoprint 2>&1
echo
printf "Nacisnij Enter aby zamknac..."
read -r _
