#!/usr/bin/env bash
# ── post-install-debian13.sh ──────────────────────────────────────────────────
# Debian 13 (Trixie) · GNOME desktop · post-install bootstrap
#
# Run from an active GNOME Terminal as your normal user.
# Do NOT run this script with sudo.
#
# One-liner:
#   tmp="$(mktemp)" && wget -qO "$tmp" "https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/post-install-deb.sh" && bash "$tmp"; rc=$?; rm -f "$tmp"; (exit "$rc")
#
# Manual usage:
#   wget -O post-install-debian13.sh "https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/post-install-deb.sh"
#   chmod +x post-install-debian13.sh
#   ./post-install-debian13.sh
# ─────────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail
trap 'printf "\nERROR at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ── Config ────────────────────────────────────────────────────────────────────
TZ="Europe/Berlin"
LOCALE="en_US.UTF-8"
FULL_UPGRADE=1              # 0 = apt upgrade only; 1 = apt full-upgrade

# Flatpak apps to install from Flathub
FLATPAK_APPS=(
    io.gitlab.librewolf-community
    org.mozilla.Thunderbird
    com.bitwarden.desktop
    com.mattjakeman.ExtensionManager
    io.missioncenter.MissionCenter
    com.github.tchx84.Flatseal
    org.gnome.World.Secrets
    com.visualstudio.code
    # org.gimp.GIMP
    # org.inkscape.Inkscape
    # com.obsproject.Studio
    # net.ankiweb.Anki
)

# APT packages
BASE_PACKAGES=(
    timeshift
    ca-certificates
    curl
    wget
    git
    btop
    fastfetch
    locales
    flatpak
    gnome-software-plugin-flatpak
    podman
    distrobox
    wireguard
    nm-connection-editor
    gnome-boxes
    gnome-tweaks
    gnome-shell-extensions
    gnome-terminal
    gedit
    fonts-jetbrains-mono
    # fonts-firacode
    xclip
    rsync
    unzip
    jq
)

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf '\n\e[1;34m──\e[0m %s\n' "$*"; }
success() { printf '\e[1;32m✓\e[0m %s\n' "$*"; }
warn()    { printf '\e[1;33m!\e[0m %s\n' "$*"; }
die()     { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    cat >&2 <<'EOF'
ERROR: Do not run this script as root.

Run it as your normal GNOME desktop user.

Correct:
  bash post-install-debian13.sh

Correct one-liner:
  tmp="$(mktemp)" && wget -qO "$tmp" "https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/post-install-deb.sh" && bash "$tmp"; rc=$?; rm -f "$tmp"; (exit "$rc")

Wrong:
  sudo bash post-install-debian13.sh
EOF
    exit 1
fi

command -v sudo >/dev/null 2>&1 || die "sudo is missing."
command -v apt-get >/dev/null 2>&1 || die "apt-get is missing. This script is intended for Debian."
command -v gsettings >/dev/null 2>&1 || warn "gsettings not found yet; GNOME settings may fail until packages are installed."

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

# Enable English and German UTF-8 locales.
sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo sed -i 's/^# *de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo localectl set-locale LANG="$LOCALE"

success "Timezone: $TZ  Locale: $LOCALE"

# ── Flatpak ───────────────────────────────────────────────────────────────────
info "Configuring Flatpak + Flathub"

sudo flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo

sudo flatpak update --system -y

info "Installing Flatpak apps"

FLATPAK_INSTALLED=0
FLATPAK_SKIPPED=0
FLATPAK_FAILED=0

for app in "${FLATPAK_APPS[@]}"; do
    if flatpak info --system "$app" &>/dev/null; then
        warn "$app already installed — skipping"
        FLATPAK_SKIPPED=$((FLATPAK_SKIPPED + 1))
    else
        if sudo flatpak install --system --assumeyes flathub "$app"; then
            success "Installed $app"
            FLATPAK_INSTALLED=$((FLATPAK_INSTALLED + 1))
        else
            warn "Failed to install $app — continuing"
            FLATPAK_FAILED=$((FLATPAK_FAILED + 1))
        fi
    fi
done

# ── LibreWolf settings ────────────────────────────────────────────────────────
# Applies LibreWolf Flatpak defaults through librewolf.overrides.cfg.
info "Configuring LibreWolf settings"

if flatpak info --system io.gitlab.librewolf-community &>/dev/null; then
    LIBREWOLF_CFG_DIR="$HOME/.var/app/io.gitlab.librewolf-community/.librewolf"
    LIBREWOLF_CFG="$LIBREWOLF_CFG_DIR/librewolf.overrides.cfg"

    mkdir -p "$LIBREWOLF_CFG_DIR"

    if [[ -f "$LIBREWOLF_CFG" ]]; then
        cp -a "$LIBREWOLF_CFG" "${LIBREWOLF_CFG}.bak.$(date +%Y%m%d-%H%M%S)"
        warn "Existing LibreWolf overrides backed up"
    fi

    cat > "$LIBREWOLF_CFG" <<'EOF'
// LibreWolf user overrides generated by post-install-debian13.sh

// Enable Firefox Sync
defaultPref("identity.fxaccounts.enabled", true);

// Home page URL
defaultPref("browser.startup.homepage", "https://start.duckduckgo.com");

// Restore previous windows and tabs on normal startup
defaultPref("browser.startup.page", 3);

// Restore previous session after crash
defaultPref("browser.sessionstore.resume_from_crash", true);

// Preserve browsing and download history
defaultPref("privacy.clearOnShutdown.history", false);
defaultPref("privacy.clearOnShutdown.downloads", false);

// Preserve login/session data across browser restarts
defaultPref("privacy.clearOnShutdown.cookies", false);
defaultPref("privacy.clearOnShutdown.sessions", false);
defaultPref("privacy.clearOnShutdown.offlineApps", false);
defaultPref("network.cookie.lifetimePolicy", 0);

// Enable middle-click autoscroll, but prevent middle-click paste
defaultPref("middlemouse.paste", false);
defaultPref("general.autoScroll", true);

// Use a stricter autoplay policy
defaultPref("media.autoplay.blocking_policy", 2);

// Show Home button in the navigation toolbar
// NOTE: This sets the toolbar layout for fresh/default profiles.
defaultPref("browser.uiCustomization.state", "{\"placements\":{\"widget-overflow-fixed-list\":[],\"unified-extensions-area\":[],\"nav-bar\":[\"back-button\",\"forward-button\",\"stop-reload-button\",\"home-button\",\"urlbar-container\",\"downloads-button\",\"unified-extensions-button\"],\"toolbar-menubar\":[\"menubar-items\"],\"TabsToolbar\":[\"tabbrowser-tabs\",\"new-tab-button\",\"alltabs-button\"],\"PersonalToolbar\":[\"personal-bookmarks\"]},\"seen\":[\"home-button\"],\"dirtyAreaCache\":[\"nav-bar\",\"TabsToolbar\",\"toolbar-menubar\",\"PersonalToolbar\"],\"currentVersion\":20}");

// Keep WebGL disabled by default for privacy/fingerprinting resistance.
// Uncomment only if needed for specific websites.
// defaultPref("webgl.disabled", false);
EOF

    chmod 0644 "$LIBREWOLF_CFG"
    success "LibreWolf settings written to $LIBREWOLF_CFG"
else
    warn "LibreWolf Flatpak not installed — skipping LibreWolf settings"
fi

# ── Distrobox ─────────────────────────────────────────────────────────────────
info "podman + distrobox ready"
success "Run 'distrobox create --name <name> --image <image>' to create containers"

# ── .bashrc additions ─────────────────────────────────────────────────────────
info "Patching .bashrc"

BASHRC_MARKER="# >>> post-install additions <<<"

if [[ ! -f "$HOME/.bashrc" ]]; then
    touch "$HOME/.bashrc"
fi

if grep -qF "$BASHRC_MARKER" "$HOME/.bashrc"; then
    warn ".bashrc already patched — skipping"
else
    cat >> "$HOME/.bashrc" <<'EOF'

# >>> post-install additions <<<

# Show system info when opening an interactive terminal
if [[ $- == *i* ]] && [[ -t 1 ]] && command -v fastfetch >/dev/null 2>&1; then
    if [[ -z "${FASTFETCH_SHOWN:-}" ]]; then
        fastfetch
        export FASTFETCH_SHOWN=1
    fi
fi

# Show container distro and hostname in prompt when inside distrobox/podman
if [ -n "${CONTAINER_ID:-}" ]; then
    _distro=$(source /etc/os-release && echo "$ID")
    PS1="[box:${_distro}@\h] $PS1"
    unset _distro
fi

# Handy aliases
alias ll='ls -lah --color=auto'
alias gs='git status'
alias glog='git log --oneline --graph --decorate --all'
alias dps='distrobox list'

# Better history
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
    warn "No active GNOME D-Bus session — skipping gsettings. Run from a GNOME Terminal."
else
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
    gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true
    gsettings set org.gnome.desktop.interface show-battery-percentage true
    gsettings set org.gnome.desktop.interface clock-show-seconds true
    gsettings set org.gnome.desktop.interface clock-show-weekday true
    # Window buttons: minimize, maximize, close on the right side
    gsettings set org.gnome.desktop.wm.preferences button-layout ':minimize,maximize,close'
    # Keyboard layouts: English US + German + Montenegrin Latin
    gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'de'), ('xkb', 'me')]"
    gsettings set org.gnome.desktop.input-sources current 0
    gsettings set org.gnome.desktop.input-sources per-window false

    # JetBrains Mono in GNOME Terminal, if the schema exists.
    if gsettings list-schemas 2>/dev/null | grep -q '^org.gnome.Terminal.ProfilesList$'; then
        TERM_PROFILE="$(gsettings get org.gnome.Terminal.ProfilesList default | tr -d "'")"

        if [[ -n "$TERM_PROFILE" ]]; then
            TERM_SCHEMA="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${TERM_PROFILE}/"
            gsettings set "$TERM_SCHEMA" use-system-font false
            gsettings set "$TERM_SCHEMA" font 'JetBrains Mono 12'
        else
            warn "Could not detect GNOME Terminal profile — skipping terminal font setting"
        fi
    else
        warn "GNOME Terminal schema not found — skipping terminal font setting"
    fi

    success "GNOME settings applied"
fi

# ── Pin apps to GNOME Dash ────────────────────────────────────────────────────
# NOTE: This replaces the entire favorites list.
info "Pinning apps to Dash"

if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    DASH_FAVORITES="[
        'org.gnome.Nautilus.desktop',
        'io.gitlab.librewolf-community.desktop',
        'org.mozilla.Thunderbird.desktop',
        'com.visualstudio.code.desktop',
        'org.gnome.Terminal.desktop',
        'org.gnome.gedit.desktop',
        'org.gnome.Boxes.desktop',
        'com.mattjakeman.ExtensionManager.desktop',
        'io.missioncenter.MissionCenter.desktop'
    ]"

    gsettings set org.gnome.shell favorite-apps "$DASH_FAVORITES"
    success "Dash updated"
else
    warn "No active GNOME D-Bus session — skipping Dash pinning"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
info "Enabling unattended upgrades"
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
printf '  • Log back in after reboot for .bashrc + GNOME changes to fully take effect\n'
printf '  • Create your first Distrobox after reboot:\n'
printf '      distrobox create --name deb-1 --image debian:bookworm\n'
printf '  • System will reboot automatically now.\n'
printf '  ────────────────────────────────────────\n'
printf '\n'

# ── Mandatory reboot ──────────────────────────────────────────────────────────
info "Mandatory reboot"
warn "System will reboot now to apply kernel, firmware, Flatpak, GNOME, and package changes."
sync
sudo systemctl reboot
