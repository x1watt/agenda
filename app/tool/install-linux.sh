#!/usr/bin/env bash
# Builds agenda, installs it under ~/.local, adds the app launcher (pin it to
# the dock from the app grid), starts it at login minimised to the tray, and
# enables the background checker (systemd user timer).
#
#   tool/install-linux.sh              install, autostart + background checks
#   tool/install-linux.sh --no-auto    install only (no autostart, timer off)
#   tool/install-linux.sh --uninstall  remove everything except your data

set -euo pipefail

APP_ID="agenda"
WM_CLASS="x1watt.agenda"
PREFIX="${HOME}/.local"
INSTALL_DIR="${PREFIX}/opt/${APP_ID}"
BIN_LINK="${PREFIX}/bin/${APP_ID}"
DESKTOP_DIR="${PREFIX}/share/applications"
DESKTOP_FILE="${DESKTOP_DIR}/${APP_ID}.desktop"
AUTOSTART_FILE="${HOME}/.config/autostart/${APP_ID}.desktop"
UNIT_DIR="${HOME}/.config/systemd/user"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENDA_DIR="$(cd "${APP_DIR}/.." && pwd)"

if [[ "${1:-}" == "--uninstall" ]]; then
  systemctl --user disable --now agenda-check.timer 2>/dev/null || true
  rm -rf "${INSTALL_DIR}" "${BIN_LINK}" "${PREFIX}/bin/agenda-mail" "${PREFIX}/bin/agenda-new" "${DESKTOP_FILE}" "${AUTOSTART_FILE}" \
    "${UNIT_DIR}/agenda-check.service" "${UNIT_DIR}/agenda-check.timer" "${UNIT_DIR}/agenda-check.timer.d"
  systemctl --user daemon-reload
  echo "Removed ${APP_ID}. Tasks, runs and settings (~/.config/agenda) were kept."
  exit 0
fi

# This machine hard-freezes when two heavy builds run at once: always go
# through the machine-wide build lock.
FLUTTER_CMD=(flutter)
if [[ -x "${HOME}/bin/android-build-locked" ]]; then
  FLUTTER_CMD=("${HOME}/bin/android-build-locked" flutter)
fi

echo "Building release bundle..."
cd "${APP_DIR}"
"${FLUTTER_CMD[@]}" build linux --release
BUNDLE="${APP_DIR}/build/linux/x64/release/bundle"
[[ -d "${BUNDLE}" ]] || { echo "Build produced no bundle at ${BUNDLE}"; exit 1; }

echo "Compiling the background checker..."
mkdir -p "${APP_DIR}/build/checker"
(cd "${AGENDA_DIR}/core" && dart pub get >/dev/null && \
  dart compile exe bin/agenda_check.dart -o "${APP_DIR}/build/checker/agenda_check" >/dev/null && \
  dart compile exe bin/protonmail.dart -o "${APP_DIR}/build/checker/agenda-mail" >/dev/null && \
  dart compile exe bin/agenda_new.dart -o "${APP_DIR}/build/checker/agenda-new" >/dev/null)

echo "Installing to ${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}" "${PREFIX}/bin" "${DESKTOP_DIR}" "${UNIT_DIR}"
cp -a "${BUNDLE}/." "${INSTALL_DIR}/"
cp "${APP_DIR}/build/checker/agenda_check" "${APP_DIR}/build/checker/agenda-mail" "${APP_DIR}/build/checker/agenda-new" "${INSTALL_DIR}/"
cp "${APP_DIR}/assets/icon.png" "${INSTALL_DIR}/icon.png"
ln -sfn "${INSTALL_DIR}/agenda" "${BIN_LINK}"
ln -sfn "${INSTALL_DIR}/agenda-mail" "${PREFIX}/bin/agenda-mail"
ln -sfn "${INSTALL_DIR}/agenda-new" "${PREFIX}/bin/agenda-new"

write_desktop() {
  local path="$1" extra_exec="$2"
  cat > "${path}" <<DESKTOP
[Desktop Entry]
Type=Application
Name=agenda
Comment=Claude-powered assistant for the daily tasks
Exec=${INSTALL_DIR}/agenda${extra_exec}
Path=${INSTALL_DIR}
Icon=${INSTALL_DIR}/icon.png
Terminal=false
Categories=Office;Utility;
StartupNotify=true
StartupWMClass=${WM_CLASS}
DESKTOP
  chmod +x "${path}"
}
write_desktop "${DESKTOP_FILE}" ""

cat > "${UNIT_DIR}/agenda-check.service" <<UNIT
[Unit]
Description=agenda: check tasks and mail, wake Claude when needed
After=graphical-session.target

[Service]
Type=oneshot
WorkingDirectory=${AGENDA_DIR}
Environment=PATH=${HOME}/.local/bin:${HOME}/flutter/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${INSTALL_DIR}/agenda_check
# A full Claude review is capped at 20 minutes by the checker itself.
TimeoutStartSec=30min
Nice=10
UNIT

cat > "${UNIT_DIR}/agenda-check.timer" <<UNIT
[Unit]
Description=agenda: check shortly after login, then every 30 minutes

[Timer]
OnStartupSec=3min
OnUnitActiveSec=30min
AccuracySec=1min

[Install]
WantedBy=timers.target
UNIT
systemctl --user daemon-reload

if [[ "${1:-}" != "--no-auto" ]]; then
  mkdir -p "$(dirname "${AUTOSTART_FILE}")"
  write_desktop "${AUTOSTART_FILE}" " --start-minimized"
  cat >> "${AUTOSTART_FILE}" <<DESKTOP
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
DESKTOP
  systemctl --user enable --now agenda-check.timer
  echo "Autostart enabled and background checks on."
fi

command -v update-desktop-database >/dev/null && \
  update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true

echo
echo "Installed. Open 'agenda' from the app grid and pin it to the dock."
echo "Timer: $(systemctl --user list-timers agenda-check.timer --no-legend --no-pager 2>/dev/null)"
