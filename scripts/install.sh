#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/build}"

if [[ ! -x "${WORK_DIR}/sunshine-build/sunshine" ]]; then
  echo "Build output not found. Run scripts/build.sh first." >&2
  exit 1
fi

systemctl --user stop app-dev.lizardbyte.app.Sunshine.service 2>/dev/null || true

if [[ -x /usr/bin/sunshine && ! -e /usr/bin/sunshine.pre-jetson ]]; then
  sudo cp --preserve=mode,timestamps /usr/bin/sunshine /usr/bin/sunshine.pre-jetson
fi

sudo cmake --install "${WORK_DIR}/nvmpi-build" --prefix /usr/local
sudo ldconfig
sudo cmake --install "${WORK_DIR}/sunshine-build"
sudo setcap cap_sys_admin,cap_sys_nice+p /usr/bin/sunshine
sudo udevadm control --reload-rules
sudo udevadm trigger

systemctl --user daemon-reload
systemctl --user start app-dev.lizardbyte.app.Sunshine.service
systemctl --user --no-pager status app-dev.lizardbyte.app.Sunshine.service
