#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/build}"
sunshine="${WORK_DIR}/sunshine-build/sunshine"
nvmpi_lib="${WORK_DIR}/nvmpi-build"

if [[ ! -x "${sunshine}" ]]; then
  echo "Build output not found. Run scripts/build.sh first." >&2
  exit 1
fi
if [[ -z "${DISPLAY:-}" ]]; then
  echo "DISPLAY is not set; run this script from the graphical session." >&2
  exit 1
fi

was_active=0
if systemctl --user is-active --quiet app-dev.lizardbyte.app.Sunshine.service; then
  was_active=1
  systemctl --user stop app-dev.lizardbyte.app.Sunshine.service
fi

restore_service() {
  if (( was_active )); then
    systemctl --user start app-dev.lizardbyte.app.Sunshine.service
  fi
}
trap restore_service EXIT

log_file="${WORK_DIR}/encoder-probe.log"
set +e
timeout --signal=INT 15s env LD_LIBRARY_PATH="${nvmpi_lib}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
  "${sunshine}" -1 capture=x11 encoder=jetson 2>&1 | tee "${log_file}"
probe_status=${PIPESTATUS[0]}
set -e

if [[ ${probe_status} -ne 0 && ${probe_status} -ne 124 ]]; then
  echo "Sunshine probe failed with status ${probe_status}." >&2
  exit "${probe_status}"
fi
if ! grep -Fq "Sunshine version: 2026.516.143833 commit: 14ffa6fdaa53f7b51512be2b3d24f3939695403c" "${log_file}"; then
  echo "Built Sunshine does not report the tested upstream release." >&2
  exit 1
fi
if ! grep -Fq "Found H.264 encoder: h264_nvmpi [jetson]" "${log_file}"; then
  echo "H.264 Jetson encoder was not detected." >&2
  exit 1
fi
if ! grep -Fq "Found HEVC encoder: hevc_nvmpi [jetson]" "${log_file}"; then
  echo "HEVC Jetson encoder was not detected." >&2
  exit 1
fi

echo "Jetson H.264 and HEVC encoder probes passed."
