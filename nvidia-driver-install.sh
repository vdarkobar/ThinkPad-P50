#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

echo "==> Debian 13 NVIDIA Secure Boot / MOK / Driver installer"
echo

if [[ $EUID -eq 0 ]]; then
  echo "ERROR: Run this script as your normal user, not with sudo/root."
  echo "The script will call sudo only where needed."
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  }
}

need_cmd sudo
need_cmd apt

echo "==> Updating package lists"
sudo apt update

echo
echo "==> Running full upgrade"
sudo apt full-upgrade

echo
echo "==> Installing kernel headers, DKMS, and mokutil"
sudo apt install linux-headers-amd64 dkms mokutil

echo
echo "==> Generating DKMS MOK key"
sudo dkms generate_mok

if [[ ! -f /var/lib/dkms/mok.pub ]]; then
  echo "ERROR: /var/lib/dkms/mok.pub was not created."
  exit 1
fi

echo
echo "==> Importing DKMS MOK public key"
echo "You will now be asked to create a temporary MOK enrollment password."
echo "Remember this password. You must enter it once during the next reboot."
echo
sudo mokutil --import /var/lib/dkms/mok.pub

echo
echo "==> Pending MOK enrollment requests"
sudo mokutil --list-new || true

echo
echo "==> Installing NVIDIA driver packages"
sudo apt install nvidia-kernel-dkms nvidia-driver firmware-misc-nonfree nvtop

echo
echo "======================================================================"
echo "IMPORTANT:"
echo
echo "The NVIDIA driver packages are now installed."
echo "The system will reboot now."
echo
echo "During boot, the blue MOK Manager screen should appear."
echo
echo "Choose:"
echo "  Enroll MOK"
echo "  Continue"
echo "  Yes"
echo
echo "Then enter the password you created during the MOK import step."
echo
echo "After Debian boots again, verify with:"
echo "  mokutil --sb-state"
echo "  dkms status"
echo "  nvidia-smi"
echo "======================================================================"
echo

read -r -p "Press Enter to reboot now, or Ctrl+C to cancel..."

sudo reboot
