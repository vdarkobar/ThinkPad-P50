#!/usr/bin/env bash
set -Eeuo pipefail

# fingerprint-p50-vfs0090-debian13-nosnap.sh
# Debian 13 no-snap installer/initializer for ThinkPad P50 Validity VFS7500
# fingerprint reader: USB ID 138a:0090.
#
# Daily fingerprint use:
#   Debian fprintd + libpam-fprintd + TOD-capable libfprint + vfs0090 TOD driver.
#
# One-time sensor initialization:
#   validity-sensors-tools cloned from source into /opt/vfs0090-tools/source.
#   No snap is installed or required.
#
# Important:
#   For 138a:0090, do NOT enroll with validity-sensors-tools.
#   Initialize/pair with vfs0090-init, then enroll with fprintd-enroll.
#
# Scope:
#   Supported: Debian 13 Trixie, amd64, Validity/Synaptics VFS7500 138a:0090.
#   Refuses: non-Debian, non-Debian-13, non-amd64, missing 138a:0090 sensor.
#
# Usage:
#   chmod +x fingerprint-p50-vfs0090-debian13-nosnap.sh
#   sudo ./fingerprint-p50-vfs0090-debian13-nosnap.sh
#
# Optional:
#   sudo ./fingerprint-p50-vfs0090-debian13-nosnap.sh --yes
#   sudo ./fingerprint-p50-vfs0090-debian13-nosnap.sh --skip-init
#   sudo ./fingerprint-p50-vfs0090-debian13-nosnap.sh --skip-tod-libfprint
#   sudo ./fingerprint-p50-vfs0090-debian13-nosnap.sh --skip-pam
#
# Deliberately NOT done:
#   - No snap installation.
#   - No system D-Bus restart.
#   - No manual overwrite of:
#       /usr/share/dbus-1/system-services/net.reactivated.Fprint.service

APP_NAME="fingerprint-p50-vfs0090-debian13-nosnap"
SENSOR_USB_ID="138a:0090"
SUPPORTED_DISTRO_ID="debian"
SUPPORTED_VERSION_ID="13"
SUPPORTED_VERSION_CODENAME="trixie"
SUPPORTED_ARCH="amd64"

BASE_DIR="/opt/vfs0090-tools"
SRC_DIR="${BASE_DIR}/source"
VENV_DIR="${BASE_DIR}/venv"
STATE_DIR="${BASE_DIR}/state"
COMMON_DIR="${BASE_DIR}/common"
FIRMWARE_DIR="${BASE_DIR}/firmware"
BUILD_DIR="${BASE_DIR}/build"
DEB_DIR="${BASE_DIR}/debs"

INIT_REPO_URL="${INIT_REPO_URL:-https://github.com/vdarkobar/python-validity.git}"
# Optional: branch, tag, or commit. Empty means default branch HEAD.
INIT_REPO_REF="${INIT_REPO_REF:-}"

VFS_DRIVER_REPO_URL="${VFS_DRIVER_REPO_URL:-https://github.com/3v1n0/libfprint-tod-vfs0090.git}"
# Optional: branch, tag, or commit. Empty means default branch HEAD.
VFS_DRIVER_REPO_REF="${VFS_DRIVER_REPO_REF:-}"

# Debian 13 does not currently ship a convenient vfs0090 TOD driver package.
# This script uses Ubuntu's TOD-enabled libfprint packages as a pragmatic bridge.
# Override these if the archive path or version changes.
TOD_BASE_URL="${TOD_BASE_URL:-https://cz.archive.ubuntu.com/ubuntu/pool/main/libf/libfprint}"
TOD_VER="${TOD_VER:-1.94.9+tod1-1ubuntu0.2}"
INSTALL_TOD_LIBFPRINT="${INSTALL_TOD_LIBFPRINT:-1}"
HOLD_TOD_PACKAGES="${HOLD_TOD_PACKAGES:-1}"

LENOVO_DRIVER_URL="${LENOVO_DRIVER_URL:-https://download.lenovo.com/pccbbs/mobiles/n1cgn08w.exe}"
LENOVO_FW_NAME="${LENOVO_FW_NAME:-6_07f_Lenovo.xpfwext}"
LOCAL_FW_PATH="${LOCAL_FW_PATH:-${FIRMWARE_DIR}/${LENOVO_FW_NAME}}"

ASSUME_YES="${ASSUME_YES:-0}"
RUN_INIT="${RUN_INIT:-1}"
ENABLE_PAM="${ENABLE_PAM:-1}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '\n\033[1;31mERROR: command failed at line %s: %s\033[0m\n' "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" >&2
  exit "${exit_code}"
}
trap on_error ERR

usage() {
  cat <<EOF
${APP_NAME}

Debian 13 no-snap setup for ThinkPad P50 / Validity VFS7500 138a:0090.

Usage:
  sudo ./${APP_NAME}.sh [options]

Options:
  -y, --yes               Do not ask before running destructive sensor initialization
  --skip-init             Install packages/tools/wrappers only; do not initialize sensor
  --skip-tod-libfprint    Do not install Ubuntu TOD libfprint packages
  --skip-pam              Do not enable Debian PAM fingerprint authentication
  -h, --help              Show this help

Environment overrides:
  ASSUME_YES=1
  RUN_INIT=0
  ENABLE_PAM=0
  INSTALL_TOD_LIBFPRINT=0
  HOLD_TOD_PACKAGES=0
  TOD_BASE_URL=${TOD_BASE_URL}
  TOD_VER=${TOD_VER}
  INIT_REPO_URL=${INIT_REPO_URL}
  INIT_REPO_REF=<branch|tag|commit>
  VFS_DRIVER_REPO_URL=${VFS_DRIVER_REPO_URL}
  VFS_DRIVER_REPO_REF=<branch|tag|commit>
  LENOVO_DRIVER_URL=${LENOVO_DRIVER_URL}
  LOCAL_FW_PATH=${LOCAL_FW_PATH}

Manual firmware fallback:
  If Lenovo's official URL is unavailable, place this file before rerunning:
    ${LOCAL_FW_PATH}

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      --skip-init)
        RUN_INIT=0
        shift
        ;;
      --skip-tod-libfprint)
        INSTALL_TOD_LIBFPRINT=0
        shift
        ;;
      --skip-pam)
        ENABLE_PAM=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root, for example: sudo ./${APP_NAME}.sh"
  fi
}

require_debian13() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "${SUPPORTED_DISTRO_ID}" ]]; then
    die "This script is Debian-only. Detected: ${PRETTY_NAME:-unknown}"
  fi

  if [[ "${VERSION_ID:-}" != "${SUPPORTED_VERSION_ID}" && "${VERSION_CODENAME:-}" != "${SUPPORTED_VERSION_CODENAME}" ]]; then
    die "This script targets Debian 13/Trixie. Detected: ${PRETTY_NAME:-unknown}"
  fi

  log "Detected Debian: ${PRETTY_NAME:-Debian 13}"
}

require_amd64() {
  local arch
  arch="$(dpkg --print-architecture)"
  if [[ "${arch}" != "${SUPPORTED_ARCH}" ]]; then
    die "This script downloads ${SUPPORTED_ARCH} TOD packages. Detected architecture: ${arch}"
  fi
  log "Detected architecture: ${arch}"
}

apt_update_once() {
  if [[ "${APT_UPDATED_ONCE:-0}" != "1" ]]; then
    log "Updating APT package index"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    APT_UPDATED_ONCE=1
  fi
}

apt_install() {
  apt_update_once
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends "$@"
}

ensure_lsusb() {
  if ! command -v lsusb >/dev/null 2>&1; then
    log "Installing usbutils so the fingerprint sensor can be checked"
    apt_install usbutils
  fi
}

require_sensor() {
  ensure_lsusb

  local sensor_line
  sensor_line="$(lsusb | grep -Ei 'validity|synaptics|138a' || true)"

  if ! lsusb | grep -q "${SENSOR_USB_ID}"; then
    printf '\nDetected fingerprint-related USB devices:\n%s\n' "${sensor_line:-none}"
    die "This script only supports Validity/Synaptics VFS7500 USB ID ${SENSOR_USB_ID}. Refusing to continue."
  fi

  log "Detected supported fingerprint sensor"
  lsusb | grep "${SENSOR_USB_ID}"
}

confirm_destructive_init() {
  if [[ "${RUN_INIT}" != "1" ]]; then
    warn "Sensor initialization skipped because RUN_INIT=0 / --skip-init was used."
    return 0
  fi

  cat <<EOF

This will factory-reset and pair the ${SENSOR_USB_ID} fingerprint sensor with this laptop.

This is required before the VFS0090 driver can use this reader properly.
It is a destructive sensor-side initialization step and should only be run on
this intended ThinkPad/workstation.

Official Lenovo firmware source checked by this script:
  ${LENOVO_DRIVER_URL}

Firmware expected inside Lenovo package:
  ${LENOVO_FW_NAME}

If the official Lenovo URL is unavailable, the script will look for a manually
provided firmware file here:
  ${LOCAL_FW_PATH}

EOF

  if [[ "${ASSUME_YES}" == "1" ]]; then
    warn "ASSUME_YES=1 set; continuing without interactive confirmation."
    return 0
  fi

  local answer
  read -r -p "Continue with sensor factory-reset/pairing? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES)
      ;;
    *)
      die "Cancelled by user."
      ;;
  esac
}

stop_conflicting_services() {
  log "Stopping only fingerprint services that may hold the USB device"

  systemctl stop \
    fprintd.service \
    python3-validity.service \
    open-fprintd.service \
    open-fprintd-suspend.service \
    open-fprintd-resume.service \
    2>/dev/null || true

  pkill -f 'fprintd|python3-validity|open-fprintd|validitysensor|validity-sensors' 2>/dev/null || true
}

remove_conflicting_stack() {
  log "Removing conflicting python-validity/open-fprintd packages if present"

  systemctl disable --now \
    python3-validity.service \
    open-fprintd.service \
    open-fprintd-suspend.service \
    open-fprintd-resume.service \
    2>/dev/null || true

  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y python3-validity open-fprintd 2>/dev/null || true
  apt-get autoremove --purge -y 2>/dev/null || true
}

install_debian_packages() {
  log "Installing Debian packages"

  apt_install \
    ca-certificates \
    curl \
    wget \
    git \
    usbutils \
    fprintd \
    libpam-fprintd \
    build-essential \
    dpkg-dev \
    meson \
    ninja-build \
    pkg-config \
    gobject-introspection \
    libgirepository1.0-dev \
    libglib2.0-dev \
    libgusb-dev \
    libpixman-1-dev \
    libssl-dev \
    libnss3-dev \
    libudev-dev \
    libsystemd-dev \
    systemd-dev \
    cmake \
    libusb-1.0-0-dev \
    python3 \
    python3-venv \
    python3-dev \
    python3-pip \
    python3-usb \
    gcc \
    libgmp-dev \
    7zip
}

install_tod_libfprint() {
  if [[ "${INSTALL_TOD_LIBFPRINT}" != "1" ]]; then
    warn "Skipping TOD libfprint package installation because INSTALL_TOD_LIBFPRINT=0 / --skip-tod-libfprint was used."
    return 0
  fi

  log "Installing TOD-capable libfprint packages"

  mkdir -p "${DEB_DIR}"
  cd "${DEB_DIR}"

  local pkg deb url
  local packages=(
    gir1.2-fprint-2.0
    libfprint-2-2
    libfprint-2-dev
    libfprint-2-tod1
    libfprint-2-tod-dev
  )

  for pkg in "${packages[@]}"; do
    deb="${pkg}_${TOD_VER}_${SUPPORTED_ARCH}.deb"
    url="${TOD_BASE_URL}/${deb}"
    log "Downloading ${deb}"
    wget --tries=3 --timeout=30 --waitretry=2 -O "${deb}" "${url}"
  done

  local debs=()
  for pkg in "${packages[@]}"; do
    debs+=("./${pkg}_${TOD_VER}_${SUPPORTED_ARCH}.deb")
  done

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${debs[@]}"

  if [[ "${HOLD_TOD_PACKAGES}" == "1" ]]; then
    log "Holding TOD libfprint packages"
    apt-mark hold "${packages[@]}"
  else
    warn "Not holding TOD libfprint packages because HOLD_TOD_PACKAGES=0."
  fi

  log "Verifying TOD pkg-config metadata"
  pkg-config --modversion libfprint-2-tod-1
  pkg-config --variable=tod_driversdir libfprint-2-tod-1
}

clone_repo() {
  local url="$1"
  local ref="$2"
  local dest="$3"

  rm -rf "${dest}"
  mkdir -p "$(dirname "${dest}")"

  if [[ -n "${ref}" ]]; then
    git init "${dest}"
    git -C "${dest}" remote add origin "${url}"
    git -C "${dest}" fetch --depth 1 origin "${ref}"
    git -C "${dest}" checkout --detach FETCH_HEAD
  else
    git clone --depth 1 "${url}" "${dest}"
  fi
}

build_vfs0090_driver() {
  log "Building and installing libfprint TOD driver for VFS0090"

  if ! pkg-config --exists udev; then
    die "Missing pkg-config dependency: udev. Install systemd-dev/libudev-dev, then rerun this script."
  fi

  local driver_dir="${BUILD_DIR}/libfprint-tod-vfs0090"
  local multiarch
  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

  mkdir -p "${BUILD_DIR}"
  clone_repo "${VFS_DRIVER_REPO_URL}" "${VFS_DRIVER_REPO_REF}" "${driver_dir}"

  cd "${driver_dir}"

  meson setup build \
    --prefix=/usr \
    --libdir="lib/${multiarch}"

  ninja -C build
  meson install -C build

  udevadm control --reload-rules
  udevadm trigger
  udevadm settle || true
  ldconfig

  log "Installed TOD driver directory contents"
  local tod_dir
  tod_dir="$(pkg-config --variable=tod_driversdir libfprint-2-tod-1)"
  echo "${tod_dir}"
  ls -lah "${tod_dir}"
}

clone_initializer_source() {
  log "Installing no-snap initializer source from ${INIT_REPO_URL}"

  rm -rf "${SRC_DIR}"
  mkdir -p "${BASE_DIR}"

  clone_repo "${INIT_REPO_URL}" "${INIT_REPO_REF}" "${SRC_DIR}"

  [[ -f "${SRC_DIR}/validity-sensors-tools" ]] || die "validity-sensors-tools not found in ${SRC_DIR}"
  [[ -d "${SRC_DIR}/proto9x" ]] || die "proto9x/ not found in ${SRC_DIR}"

  chmod +x "${SRC_DIR}/validity-sensors-tools"
}

create_venv() {
  log "Creating Python virtual environment for validity-sensors-tools"

  rm -rf "${VENV_DIR}"
  mkdir -p "${STATE_DIR}" "${COMMON_DIR}" "${FIRMWARE_DIR}"

  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/python" -m pip install -U pip setuptools wheel
  "${VENV_DIR}/bin/pip" install pyusb pycryptodome fastecdsa
}

patch_time_clock() {
  log "Patching old Python time.clock() usage"

  find "${SRC_DIR}" -type f \( \
    -name "*.py" -o \
    -name "validity-sensors-tools" -o \
    -path "*/Crypto/Random/*" \
  \) -print0 | xargs -0 sed -i -E \
    -e 's/time\.clock\(\)/time.perf_counter()/g' \
    -e 's/time\.clock/time.perf_counter/g' \
    -e 's/from time import clock/from time import perf_counter as clock/g'
}

patch_flash_already_partitioned() {
  log "Patching flash-already-partitioned behavior"

  "${VENV_DIR}/bin/python" <<PY
from pathlib import Path
import re

p = Path("${SRC_DIR}/proto9x/init_flash.py")
if not p.exists():
    raise SystemExit(f"Missing expected file: {p}")

s = p.read_text()
s2 = re.sub(
    r"^(\s*)raise Exception\('Flash is already partitioned'\)",
    r"\1print('Flash is already partitioned; continuing')\n\1return",
    s,
    flags=re.MULTILINE,
)

if s2 != s:
    p.write_text(s2)
    print(f"Patched {p}")
else:
    print("Flash partition patch target not found or already patched")
PY
}

patch_fastecdsa() {
  log "Patching fastecdsa compatibility for old prehashed hex-string call"

  "${VENV_DIR}/bin/python" <<'PY'
from pathlib import Path
import fastecdsa.ecdsa as ecdsa

p = Path(ecdsa.__file__)
s = p.read_text()

if "from binascii import hexlify" in s and "unhexlify" not in s:
    s = s.replace(
        "from binascii import hexlify",
        "from binascii import hexlify, unhexlify"
    )

old = """if prehashed:
        if not isinstance(msg, (bytes, bytearray)):
            raise TypeError(f"Prehashed message must be bytes, got {type(msg)}")"""

new = """if prehashed:
        if isinstance(msg, str):
            try:
                msg = unhexlify(msg)
            except Exception:
                msg = msg.encode()
        if not isinstance(msg, (bytes, bytearray)):
            raise TypeError(f"Prehashed message must be bytes, got {type(msg)}")"""

if old in s:
    s = s.replace(old, new)
    p.write_text(s)
    print(f"Patched {p}")
else:
    print("fastecdsa patch target not found or already patched")
PY
}

apply_patches() {
  patch_time_clock
  patch_flash_already_partitioned
  patch_fastecdsa
}

write_wrappers() {
  log "Installing vfs0090 helper wrappers"

  cat > /usr/local/bin/vfs0090-tool <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR}"
SRC_DIR="${SRC_DIR}"
VENV_DIR="${VENV_DIR}"
STATE_DIR="${STATE_DIR}"
COMMON_DIR="${COMMON_DIR}"

if [[ "\${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root, for example: sudo vfs0090-tool initializer" >&2
  exit 1
fi

TOOL="\${1:-}"
if [[ -z "\${TOOL}" ]]; then
  cat <<'USAGE'
Usage:
  sudo vfs0090-tool <tool>

Tools:
  initializer
  factory-reset
  flash-firmware
  pair
  calibrate
  dump-db
  erase-db
  led-dance

Aliases:
  init        -> initializer
  reset       -> factory-reset
  led         -> led-dance
  led-test    -> led-dance

Do not use validity-sensors-tools enroll for 138a:0090.
Enroll with fprintd-enroll after initialization.
USAGE
  exit 2
fi
shift || true

case "\${TOOL}" in
  init) TOOL="initializer" ;;
  reset) TOOL="factory-reset" ;;
  led|led-test) TOOL="led-dance" ;;
  initializer|factory-reset|flash-firmware|pair|calibrate|dump-db|erase-db|led-dance)
    ;;
  enroll)
    echo "ERROR: Do not use validity-sensors-tools enroll for 138a:0090. Use fprintd-enroll instead." >&2
    exit 2
    ;;
  *)
    echo "ERROR: unsupported tool: \${TOOL}" >&2
    exit 2
    ;;
esac

cd /tmp

exec env -u LD_LIBRARY_PATH -u PYTHONHOME \
  SNAP="\${SRC_DIR}" \
  SNAP_NAME="validity-sensors-tools" \
  SNAP_DATA="\${STATE_DIR}" \
  SNAP_COMMON="\${COMMON_DIR}" \
  PYTHONPATH="\${SRC_DIR}" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "\${VENV_DIR}/bin/python" "\${SRC_DIR}/validity-sensors-tools" -t "\${TOOL}" "\$@"
EOF

  chmod +x /usr/local/bin/vfs0090-tool

  cat > /usr/local/bin/vfs0090-init <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vfs0090-tool initializer "$@"
EOF
  chmod +x /usr/local/bin/vfs0090-init

  cat > /usr/local/bin/vfs0090-led-test <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vfs0090-tool led-dance "$@"
EOF
  chmod +x /usr/local/bin/vfs0090-led-test

  cat > /usr/local/bin/vfs0090-factory-reset <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vfs0090-tool factory-reset "$@"
EOF
  chmod +x /usr/local/bin/vfs0090-factory-reset
}

lenovo_firmware_url_available() {
  # Some vendor servers behave differently for HEAD requests, so try HEAD first
  # and then a tiny ranged GET before declaring the URL unavailable.
  curl -fsSIL --max-time 20 "${LENOVO_DRIVER_URL}" >/dev/null 2>&1 \
    || curl -fsSL --max-time 20 --range 0-0 "${LENOVO_DRIVER_URL}" -o /dev/null >/dev/null 2>&1
}

resolve_initializer_firmware_args() {
  INIT_FIRMWARE_ARGS=()

  log "Checking Lenovo firmware source"
  cat <<EOF
Official Lenovo firmware source:
  ${LENOVO_DRIVER_URL}

Firmware expected inside Lenovo package:
  ${LENOVO_FW_NAME}

Local manual firmware path, used only if Lenovo's official download is unavailable:
  ${LOCAL_FW_PATH}
EOF

  local attempt
  for attempt in 1 2 3; do
    if lenovo_firmware_url_available; then
      log "Official Lenovo firmware URL is reachable"
      INIT_FIRMWARE_ARGS=()
      return 0
    fi

    warn "Official Lenovo firmware URL check failed, attempt ${attempt}/3"

    if [[ -s "${LOCAL_FW_PATH}" ]]; then
      log "Using local user-provided firmware file"
      ls -lh "${LOCAL_FW_PATH}"
      INIT_FIRMWARE_ARGS=( -f "${LOCAL_FW_PATH}" )
      return 0
    fi

    if [[ "${attempt}" -lt 3 ]]; then
      warn "Local firmware file not found yet: ${LOCAL_FW_PATH}"
      sleep 2
    fi
  done

  cat <<EOF

Official Lenovo download failed.

Manually download the Lenovo driver from:
${LENOVO_DRIVER_URL}

Then extract/copy the firmware file and place it here:
${LOCAL_FW_PATH}

Expected firmware filename:
${LENOVO_FW_NAME}

After placing the file, rerun this setup script or run:
  sudo vfs0090-init -f ${LOCAL_FW_PATH}

EOF

  die "Lenovo download is unavailable and local firmware file was not found."
}

run_initializer() {
  if [[ "${RUN_INIT}" != "1" ]]; then
    warn "Skipping sensor initialization. Wrappers are installed under /usr/local/bin."
    return 0
  fi

  resolve_initializer_firmware_args
  stop_conflicting_services

  log "Running patched VFS0090 initializer"
  /usr/local/bin/vfs0090-init "${INIT_FIRMWARE_ARGS[@]}"

  log "Giving the fingerprint reader a short moment to settle after initialization"
  sleep 2

  log "Running LED test"
  /usr/local/bin/vfs0090-led-test

  log "Giving the fingerprint reader a short moment to settle after LED test"
  sleep 1
}

enable_debian_fingerprint_auth() {
  if [[ "${ENABLE_PAM}" != "1" ]]; then
    warn "Skipping PAM fingerprint enablement because ENABLE_PAM=0 / --skip-pam was used."
    return 0
  fi

  log "Enabling Debian fingerprint authentication via pam-auth-update"

  if ! command -v pam-auth-update >/dev/null 2>&1; then
    die "pam-auth-update not found even though libpam-runtime should be installed."
  fi

  pam-auth-update --enable fprintd --force

  log "Checking PAM fprintd entry"
  grep -R "pam_fprintd.so" /etc/pam.d/common-auth || warn "pam_fprintd.so was not found in /etc/pam.d/common-auth"
}

restart_and_probe_fprintd() {
  log "Restarting fprintd and probing device"

  systemctl restart fprintd.service || true

  local target_user
  target_user="${SUDO_USER:-}"
  if [[ -z "${target_user}" || "${target_user}" == "root" ]]; then
    target_user="$(logname 2>/dev/null || true)"
  fi
  if [[ -z "${target_user}" ]]; then
    target_user="root"
  fi

  fprintd-list "${target_user}" || true
}

print_no_dbus_note() {
  cat <<'EOF'

D-Bus safety note:
  This script intentionally does NOT restart dbus-broker.service or dbus.service.
  It also does NOT overwrite:
    /usr/share/dbus-1/system-services/net.reactivated.Fprint.service

  If fprintd activation behaves oddly, reboot instead of restarting the system bus
  during an active GNOME session.

EOF
}

final_instructions() {
  local target_user
  target_user="${SUDO_USER:-}"
  if [[ -z "${target_user}" || "${target_user}" == "root" ]]; then
    target_user="$(logname 2>/dev/null || true)"
  fi
  if [[ -z "${target_user}" ]]; then
    target_user="\$USER"
  fi

  cat <<EOF

Setup phase finished.

Installed helper commands:
  sudo vfs0090-init
  sudo vfs0090-led-test
  sudo vfs0090-factory-reset
  sudo vfs0090-tool <initializer|factory-reset|led-dance|calibrate|erase-db>

Do not use validity-sensors-tools enroll for 138a:0090.
Enroll only through fprintd.

Recommended next commands as your normal user:

  fprintd-list "\$USER"
  fprintd-delete "\$USER"
  fprintd-enroll -f right-index-finger "\$USER"
  fprintd-verify "\$USER"

Test sudo/PAM fingerprint prompt:

  sudo -k
  sudo true

Useful diagnostics:

  lsusb | grep -Ei 'validity|synaptics|138a'
  dpkg -l | grep -Ei 'fprint|libfprint|tod'
  apt-mark showhold | grep -Ei 'fprint|tod'
  pkg-config --variable=tod_driversdir libfprint-2-tod-1
  systemctl status fprintd.service --no-pager
  journalctl -fu fprintd

Target user detected during install: ${target_user}

EOF
}

main() {
  parse_args "$@"
  require_root
  require_debian13
  require_amd64
  require_sensor
  confirm_destructive_init
  print_no_dbus_note
  stop_conflicting_services
  remove_conflicting_stack
  install_debian_packages
  install_tod_libfprint
  build_vfs0090_driver
  clone_initializer_source
  create_venv
  apply_patches
  write_wrappers
  run_initializer
  enable_debian_fingerprint_auth
  restart_and_probe_fprintd
  final_instructions
}

main "$@"
