#!/usr/bin/env bash
# ── post-install-debian13.sh ──────────────────────────────────────────────────
# Debian 13 (Trixie) · GNOME desktop · post-install bootstrap
# Run as your normal user — sudo is called per-block as needed.
# Usage: bash post-install-debian13.sh
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'printf "\nERROR at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ── Config ────────────────────────────────────────────────────────────────────
TZ="Europe/Berlin"          # adjust to your timezone
LOCALE="en_US.UTF-8"       # base locale
FULL_UPGRADE=1              # 0 = apt upgrade only (safer on existing installs)

# Flatpak apps to install (Flathub IDs)
FLATPAK_APPS=(
    io.gitlab.librewolf-community
    org.mozilla.Thunderbird
    org.gnome.Boxes
    com.mattjakeman.ExtensionManager   # SUGGESTION: GUI for GNOME shell extensions
    io.missioncenter.MissionCenter     # SUGGESTION: modern system monitor
    com.github.tchx84.Flatseal        # SUGGESTION: Flatpak permission manager
    org.gnome.Secrets                  # SUGGESTION: KeePass-compatible password store
    # org.gimp.GIMP
    # org.inkscape.Inkscape
    # com.obsproject.Studio
    # net.ankiweb.Anki
)

# APT packages
BASE_PACKAGES=(
    timeshift
    ca-certificates  # explicit — needed for HTTPS remotes
    curl
    wget
    git
    htop
    btop             # better htop with graphs
    fastfetch        # system info banner (neofetch dropped in Trixie)
    locales          # needed for proper locale-gen
    flatpak
    gnome-software-plugin-flatpak
    podman
    distrobox
    gnome-tweaks     # GNOME tweaks tool
    gnome-shell-extensions  # enables/disables extensions
    gnome-terminal   # explicit install — Trixie may default to gnome-console
    gedit            # classic text editor; remove if you prefer gnome-text-editor
    fonts-jetbrains-mono    # great monospace font for terminals/editors
    # fonts-firacode # alternative mono font
    xclip            # clipboard CLI tool
    rsync
    unzip
    jq               # JSON parsing in scripts
)

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf '\n\e[1;34m──\e[0m %s\n' "$*"; }
success() { printf '\e[1;32m✓\e[0m %s\n' "$*"; }
warn()    { printf '\e[1;33m!\e[0m %s\n' "$*"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    printf 'Run as your normal user, not root.\n' >&2
    exit 1
fi

# ── System update ─────────────────────────────────────────────────────────────
info "System update"
sudo apt-get update -qq
if [[ "$FULL_UPGRADE" == "1" ]]; then
    sudo apt-get full-upgrade -y
else
    sudo apt-get upgrade -y
fi

# ── Base packages ─────────────────────────────────────────────────────────────
info "Installing base packages"
sudo apt-get install -y "${BASE_PACKAGES[@]}"
success "Base packages installed"

# ── Timezone & locale ─────────────────────────────────────────────────────────
info "Timezone and locale"
sudo timedatectl set-timezone "$TZ"

# locales package already in BASE_PACKAGES; use literal patterns (. is a regex wildcard)
sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo sed -i 's/^# *de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo localectl set-locale LANG="$LOCALE"

success "Timezone: $TZ  Locale: $LOCALE"

# ── Flatpak ───────────────────────────────────────────────────────────────────
info "Configuring Flatpak + Flathub"
sudo flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
sudo flatpak update -y

info "Installing Flatpak apps"
FLATPAK_INSTALLED=0
FLATPAK_SKIPPED=0
FLATPAK_FAILED=0

for app in "${FLATPAK_APPS[@]}"; do
    if flatpak info "$app" &>/dev/null; then
        warn "$app already installed — skipping"
        ((FLATPAK_SKIPPED++))
    else
        if flatpak install --assumeyes flathub "$app"; then
            success "Installed $app"
            ((FLATPAK_INSTALLED++))
        else
            warn "Failed to install $app — continuing"
            ((FLATPAK_FAILED++))
        fi
    fi
done

# ── Distrobox ─────────────────────────────────────────────────────────────────
# podman + distrobox already installed via apt above.
# Usage examples (do not run in script — run manually as needed):
#   distrobox create --name deb-1  --image debian:bookworm
#   distrobox create --name arch-1 --image archlinux:latest
#   distrobox enter deb-1
info "podman + distrobox ready"
success "Run 'distrobox create --name <name> --image <image>' to create containers"

# ── .bashrc additions ─────────────────────────────────────────────────────────
# Uses a guard comment so this block is idempotent (safe to re-run).
info "Patching .bashrc"

BASHRC_MARKER="# >>> post-install additions <<<"
if grep -qF "$BASHRC_MARKER" "$HOME/.bashrc"; then
    warn ".bashrc already patched — skipping"
else
    cat >> "$HOME/.bashrc" <<'EOF'

# >>> post-install additions <<<

# Show container distro and hostname in prompt when inside distrobox/podman
if [ -n "$CONTAINER_ID" ]; then
    _distro=$(source /etc/os-release && echo "$ID")
    PS1="[box:${_distro}@\h] $PS1"
    unset _distro
fi

# SUGGESTION: handy aliases
alias ll='ls -lah --color=auto'
alias gs='git status'
alias glog='git log --oneline --graph --decorate --all'
alias dps='distrobox list'

# SUGGESTION: better history
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth
shopt -s histappend

# >>> end post-install additions <<<
EOF
    success ".bashrc patched"
fi

# ── GNOME settings ────────────────────────────────────────────────────────────
info "Applying GNOME settings"

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    warn "No active GNOME D-Bus session — skipping gsettings (run from a GNOME terminal)"
else
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
    gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true
    gsettings set org.gnome.desktop.interface show-battery-percentage true
    gsettings set org.gnome.desktop.interface clock-show-seconds true
    gsettings set org.gnome.desktop.interface clock-show-weekday true

    # JetBrains Mono in gnome-terminal (if installed)
    if gsettings list-schemas 2>/dev/null | grep -q 'org.gnome.Terminal'; then
        TERM_PROFILE=$(gsettings get org.gnome.Terminal.ProfilesList default | tr -d "'")
        TERM_SCHEMA="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${TERM_PROFILE}/"
        gsettings set "$TERM_SCHEMA" use-system-font false
        gsettings set "$TERM_SCHEMA" font 'JetBrains Mono 12'
    fi

    success "GNOME settings applied"
fi

# ── Pin apps to GNOME Dash ────────────────────────────────────────────────────
# NOTE: Replaces the entire favorites list. Edit to taste.
# Verify available .desktop names:  ls /usr/share/applications | grep -Ei 'terminal|gedit|nautilus'
info "Pinning apps to Dash"

if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    DASH_FAVORITES="[
        'org.gnome.Nautilus.desktop',
        'io.gitlab.librewolf-community.desktop',
        'org.mozilla.Thunderbird.desktop',
        'org.gnome.Terminal.desktop',
        'org.gnome.gedit.desktop',
        'com.mattjakeman.ExtensionManager.desktop',
        'io.missioncenter.MissionCenter.desktop'
    ]"
    gsettings set org.gnome.shell favorite-apps "$DASH_FAVORITES"
    success "Dash updated"
else
    warn "No D-Bus session — skipping Dash pinning"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
info "Enabling unattended security upgrades"
sudo apt-get install -y unattended-upgrades apt-listchanges

sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

sudo tee /etc/apt/apt.conf.d/52unattended-local >/dev/null <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

success "Unattended upgrades configured using Debian defaults, no auto-reboot"

# ── Final cleanup ─────────────────────────────────────────────────────────────
info "Cleaning up"
sudo apt-get autoremove -y
sudo apt-get clean

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n'
printf '  ────────────────────────────────────────\n'
printf '  post-install complete\n'
printf '  ────────────────────────────────────────\n'
printf '  Timezone  : %s\n' "$TZ"
printf '  Flatpaks  : %d installed, %d skipped, %d failed\n' \
    "$FLATPAK_INSTALLED" "$FLATPAK_SKIPPED" "$FLATPAK_FAILED"
printf '\n'
printf '  Next steps:\n'
printf '  • Log out and back in for .bashrc + GNOME changes to fully take effect\n'
printf '  • Reboot recommended to apply kernel/firmware upgrades:\n'
printf '      sudo reboot\n'
printf '  • Create your first Distrobox:\n'
printf '      distrobox create --name deb-1 --image debian:bookworm\n'
printf '  ────────────────────────────────────────\n'
printf '\n'

# NOTE: reboot is intentionally not automatic — you choose when.
