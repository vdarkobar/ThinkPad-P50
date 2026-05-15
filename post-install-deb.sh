#!/usr/bin/env bash
# ── post-install-debian13.sh ──────────────────────────────────────────────────
# Debian 13 (Trixie) · GNOME desktop · post-install bootstrap
#
# Run from an active GNOME Terminal as your normal user.
# Do NOT run this script with sudo.
#
# Uses set -u intentionally; use ${VAR:-} for optional environment variables.
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
# Version: direct-gsettings-v3 — direct GNOME settings, pipefail-safe checks, no Nautilus APT package.
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
    # org.gimp.GIMP
    # org.inkscape.Inkscape
    # com.obsproject.Studio
    # net.ankiweb.Anki
)

# APT packages
# ca-certificates, wget, and gpg are installed earlier as repository prerequisites.
BASE_PACKAGES=(
    timeshift
    curl
    git
    code
    btop
    fastfetch
    locales
    flatpak
    gnome-software-plugin-flatpak
    podman
    distrobox
    uidmap
    fuse-overlayfs
    slirp4netns
    passt
    wireguard
    nm-connection-editor
    gnome-boxes
    gnome-tweaks
    gnome-shell-extensions
    gnome-terminal
    gedit
    gsettings-desktop-schemas
    gnome-settings-daemon
    libglib2.0-bin
    dconf-cli
    fonts-jetbrains-mono
    # fonts-firacode
    xclip
    wl-clipboard
    bash-completion
    rsync
    unzip
    jq
    fwupd
    gnome-firmware
    upower
    power-profiles-daemon
    firmware-linux-nonfree
    intel-microcode
    plocate
    seahorse
    pavucontrol
    needrestart
    tealdeer             # provides the tldr command on Debian 13/Trixie
    apparmor-utils
)

# APT should not stop for conffile prompts or package frontends.
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)

DEB822_SRC="/etc/apt/sources.list.d/debian.sources"
LEGACY_SRC="/etc/apt/sources.list"
MS_KEY_FINGERPRINT="BC528686B50D79E339D3721CEB3E94ADBE1229CF"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf '\n\e[1;34m──\e[0m %s\n' "$*"; }
success() { printf '\e[1;32m✓\e[0m %s\n' "$*"; }
warn()    { printf '\e[1;33m!\e[0m %s\n' "$*"; }
die()     { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

apt_update() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

apt_run() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" "$@"
}

remove_power_profile_conflicts() {
    local pkg
    local conflicts=()

    for pkg in tlp tlp-rdw tuned tuned-utils; do
        if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii '; then
            conflicts+=("$pkg")
        fi
    done

    if ((${#conflicts[@]})); then
        info "Removing conflicting power profile managers"
        warn "Removing packages that conflict with power-profiles-daemon: ${conflicts[*]}"

        if apt_run remove -y "${conflicts[@]}"; then
            success "Conflicting power profile managers removed"
        else
            warn "Could not remove conflicting power profile managers — base package install may fail"
        fi
    fi
}

gsettings_has_schema() {
    local schema="$1"

    # Do not use grep -q here. With set -o pipefail, grep -q can close the pipe
    # early after a match, causing gsettings to receive SIGPIPE and making the
    # whole pipeline look like a false negative.
    gsettings list-schemas 2>/dev/null | awk -v wanted="$schema" '
        $0 == wanted { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

gsettings_has_key() {
    local schema="$1"
    local key="$2"

    gsettings list-keys "$schema" 2>/dev/null | awk -v wanted="$key" '
        $0 == wanted { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

gset() {
    local schema="$1"
    local key="$2"
    local value="$3"

    if gsettings_has_schema "$schema" && gsettings_has_key "$schema" "$key"; then
        if ! gsettings set "$schema" "$key" "$value"; then
            warn "Failed to set GNOME setting: $schema $key"
        fi
    else
        warn "Skipping missing GNOME setting: $schema $key"
    fi
}

gset_path() {
    local schema_path="$1"
    local key="$2"
    local value="$3"

    if gsettings_has_key "$schema_path" "$key"; then
        if ! gsettings set "$schema_path" "$key" "$value"; then
            warn "Failed to set GNOME setting: $schema_path $key"
        fi
    else
        warn "Skipping missing GNOME setting: $schema_path $key"
    fi
}

enable_contrib_nonfree_deb822() {
    [[ -f "$DEB822_SRC" ]] || return 1

    local tmp rc
    tmp="$(mktemp)"

    if awk '
function has(a, n, v, i) {
    for (i = 1; i <= n; i++) if (a[i] == v) return 1
    return 0
}
BEGIN { found = 0; changed = 0 }
/^Components:/ {
    delete comps
    n = 0
    for (i = 2; i <= NF; i++) comps[++n] = $i

    if (has(comps, n, "main") && has(comps, n, "non-free-firmware")) {
        found = 1
        out = "Components:"
        for (i = 1; i <= n; i++) {
            out = out " " comps[i]
            if (comps[i] == "main") {
                if (!has(comps, n, "contrib"))  { out = out " contrib";  changed = 1 }
                if (!has(comps, n, "non-free")) { out = out " non-free"; changed = 1 }
            }
        }
        print out
        next
    }
}
{ print }
END {
    if (!found) exit 2
    if (!changed) exit 1
    exit 0
}
' "$DEB822_SRC" > "$tmp"; then
        rc=0
    else
        rc=$?
    fi

    case "$rc" in
        0)
            sudo cp -a "$DEB822_SRC" "${DEB822_SRC}.bak.$(date +%Y%m%d-%H%M%S)"
            sudo install -o root -g root -m 0644 "$tmp" "$DEB822_SRC"
            rm -f "$tmp"
            return 0
            ;;
        1)
            rm -f "$tmp"
            return 0
            ;;
        *)
            rm -f "$tmp"
            return 1
            ;;
    esac
}

enable_contrib_nonfree_legacy() {
    [[ -f "$LEGACY_SRC" ]] || return 1

    local tmp rc
    tmp="$(mktemp)"

    if awk '
function has_component(n, arr, want,    i) {
    for (i = 1; i <= n; i++) {
        if (arr[i] == want) return 1
    }
    return 0
}
function emit_components(n, arr,    i, out) {
    out = "main"
    if (has_component(n, arr, "contrib")) out = out " contrib"
    else out = out " contrib"
    if (has_component(n, arr, "non-free")) out = out " non-free"
    else out = out " non-free"
    if (has_component(n, arr, "non-free-firmware")) out = out " non-free-firmware"
    return out
}
/^deb(-src)?[[:space:]]/ {
    # Legacy source lines are: deb [options] URI suite components...
    # Find the suite field after an optional [options] block, then tokenize components exactly.
    split($0, f, /[[:space:]]+/)
    suite_i = 3
    if (f[2] ~ /^\[/) {
        for (i = 2; i <= length(f); i++) {
            if (f[i] ~ /\]$/) {
                suite_i = i + 2
                break
            }
        }
    }
    comp_start = suite_i + 1
    n = 0
    delete comps
    for (i = comp_start; i <= length(f); i++) {
        if (f[i] == "") continue
        comps[++n] = f[i]
    }
    if (has_component(n, comps, "main") && has_component(n, comps, "non-free-firmware")) {
        found = 1
        if (!has_component(n, comps, "contrib") || !has_component(n, comps, "non-free")) {
            changed = 1
            prefix = ""
            for (i = 1; i < comp_start; i++) {
                prefix = prefix (i == 1 ? "" : " ") f[i]
            }
            print prefix " " emit_components(n, comps)
            next
        }
    }
}
{ print }
END {
    if (!found) exit 2
    if (!changed) exit 1
    exit 0
}
' "$LEGACY_SRC" > "$tmp"; then
        rc=0
    else
        rc=$?
    fi

    case "$rc" in
        0)
            sudo cp -a "$LEGACY_SRC" "${LEGACY_SRC}.bak.$(date +%Y%m%d-%H%M%S)"
            sudo install -o root -g root -m 0644 "$tmp" "$LEGACY_SRC"
            rm -f "$tmp"
            return 0
            ;;
        1)
            rm -f "$tmp"
            return 0
            ;;
        *)
            rm -f "$tmp"
            return 1
            ;;
    esac
}

configure_apt_prompt_policy() {
    info "Configuring noninteractive APT helper policy"

    # Avoid apt-listchanges opening a pager during future apt runs.
    if command -v debconf-set-selections >/dev/null 2>&1; then
        printf 'apt-listchanges apt-listchanges/frontend select none\n' | sudo debconf-set-selections || true
    fi

    sudo install -D -m 0644 /dev/stdin /etc/apt/listchanges.conf.d/50-local.conf <<'EOFAPTLC'
[apt]
frontend=none
EOFAPTLC

    # Avoid needrestart service/kernel prompts during package installs/upgrades.
    sudo install -D -m 0644 /dev/stdin /etc/needrestart/conf.d/50-autorestart.conf <<'EOFNR'
# Restart services automatically; do not prompt.
$nrconf{restart} = 'a';
# Do not prompt about kernel/microcode either.
$nrconf{kernelhints} = -1;
EOFNR

    success "APT helper policy configured"
}

configure_vscode_repo() {
    info "Configuring Microsoft VS Code APT repository"

    local tmp_asc tmp_key got_fps
    tmp_asc="$(mktemp)"
    tmp_key="$(mktemp)"

    wget -qO "$tmp_asc" https://packages.microsoft.com/keys/microsoft.asc

    got_fps="$(gpg --show-keys --with-colons "$tmp_asc" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10}')"

    if ! grep -qxF "$MS_KEY_FINGERPRINT" <<<"$got_fps"; then
        die "Microsoft GPG key fingerprint mismatch (got: ${got_fps//$'\n'/, })"
    fi

    gpg --dearmor < "$tmp_asc" > "$tmp_key"
    sudo install -D -o root -g root -m 0644 "$tmp_key" /usr/share/keyrings/microsoft.gpg
    rm -f "$tmp_asc" "$tmp_key"

    # Keep backup copies outside /etc/apt/sources.list.d/.
    # APT scans that directory and warns about backup filenames with invalid extensions.
    local backup_dir backup_stamp backup_file
    backup_dir="/var/backups/post-install-debian13/apt-sources"
    backup_stamp="$(date +%Y%m%d-%H%M%S)"
    sudo install -d -o root -g root -m 0755 "$backup_dir"

    for backup_file in \
        /etc/apt/sources.list.d/vscode.list.bak.* \
        /etc/apt/sources.list.d/vscode.sources.bak.*; do
        [[ -e "$backup_file" ]] || continue
        sudo mv "$backup_file" "$backup_dir/"
        warn "Moved old VS Code source backup out of APT source directory: $(basename "$backup_file")"
    done

    if [[ -f /etc/apt/sources.list.d/vscode.list ]]; then
        sudo mv /etc/apt/sources.list.d/vscode.list \
            "$backup_dir/vscode.list.$backup_stamp.bak"
        warn "Backed up old vscode.list to avoid duplicate VS Code APT source"
    fi

    if [[ -f /etc/apt/sources.list.d/vscode.sources ]]; then
        sudo cp -a /etc/apt/sources.list.d/vscode.sources \
            "$backup_dir/vscode.sources.$backup_stamp.bak"
    fi

    sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOFVS'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64
Signed-By: /usr/share/keyrings/microsoft.gpg
EOFVS

    success "Microsoft VS Code APT repository configured"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    cat >&2 <<'EOFROOT'
ERROR: Do not run this script as root.

Run it as your normal GNOME desktop user.

Correct:
  bash post-install-debian13.sh

Correct one-liner:
  tmp="$(mktemp)" && wget -qO "$tmp" "https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/post-install-deb.sh" && bash "$tmp"; rc=$?; rm -f "$tmp"; (exit "$rc")

Wrong:
  sudo bash post-install-debian13.sh
EOFROOT
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
else
    die "/etc/os-release missing."
fi

[[ "${ID:-}" == "debian" ]] || die "This script is intended for Debian only."
[[ "${VERSION_CODENAME:-}" == "trixie" ]] || die "This script is intended for Debian 13/Trixie only."

command -v sudo >/dev/null 2>&1 || die "sudo is missing."
command -v apt-get >/dev/null 2>&1 || die "apt-get is missing. This script is intended for Debian."
command -v awk >/dev/null 2>&1 || die "awk is missing."
command -v wget >/dev/null 2>&1 || die "wget is missing."
command -v gsettings >/dev/null 2>&1 || warn "gsettings not found yet; GNOME settings may fail until packages are installed."

# ── APT sources: enable contrib/non-free ──────────────────────────────────────
info "Checking APT sources"

if enable_contrib_nonfree_deb822 || enable_contrib_nonfree_legacy; then
    success "Confirmed contrib and non-free APT components"
else
    warn "Could not enable contrib/non-free — neither Debian source file matched expected layout"
    warn "Packages from contrib/non-free may fail to install, especially intel-microcode"
fi

# ── System update ─────────────────────────────────────────────────────────────
info "Initial APT update"
apt_update

info "Installing repository prerequisites"
apt_run install -y ca-certificates wget gpg

configure_apt_prompt_policy
configure_vscode_repo

info "APT update with VS Code repository"
apt_update

info "System upgrade"
if [[ "$FULL_UPGRADE" == "1" ]]; then
    apt_run full-upgrade -y
else
    apt_run upgrade -y
fi

# ── Base packages ─────────────────────────────────────────────────────────────
remove_power_profile_conflicts

info "Installing base packages"
apt_run install -y "${BASE_PACKAGES[@]}"
success "Base packages installed"

# ── Rootless Podman/Distrobox readiness ───────────────────────────────────────
info "Checking rootless Podman/Distrobox setup"

if ! grep -q "^${USER}:" /etc/subuid; then
    sudo usermod --add-subuids 100000-165535 "$USER"
    warn "Added subuid range for $USER"
fi

if ! grep -q "^${USER}:" /etc/subgid; then
    sudo usermod --add-subgids 100000-165535 "$USER"
    warn "Added subgid range for $USER"
fi

success "Rootless Podman/Distrobox prerequisites checked"
success "After reboot, run: distrobox create --name <name> --image <image>"

# ── Battery health charging threshold ─────────────────────────────────────────
# Enables GNOME/UPower "Preserve Battery Health" when supported by hardware.
info "Checking battery health charging threshold support"

if ! command -v upower >/dev/null 2>&1; then
    warn "upower not found — skipping battery health charging threshold"
elif ! command -v busctl >/dev/null 2>&1; then
    warn "busctl not found — skipping battery health charging threshold"
else
    BATTERY_PATH="$(upower -e 2>/dev/null | grep -m1 '/battery_' || true)"

    if [[ -z "$BATTERY_PATH" ]]; then
        warn "No UPower battery device found — skipping battery health charging threshold"
    elif upower -i "$BATTERY_PATH" 2>/dev/null | grep -Eq 'charge-threshold-supported:[[:space:]]*yes'; then
        if sudo busctl call org.freedesktop.UPower \
            "$BATTERY_PATH" \
            org.freedesktop.UPower.Device \
            EnableChargeThreshold b true >/dev/null 2>&1; then
            success "Battery health charging threshold enabled"
            upower -i "$BATTERY_PATH" | grep -E 'charge-(start|end)-threshold|charge-threshold' || true
        else
            warn "Failed to enable battery health charging threshold via UPower"
        fi
    else
        warn "Battery health charging threshold not supported/reported by UPower on this device"
    fi
fi

# ── Automatic power profile switching ─────────────────────────────────────────
# AC power -> performance, if supported; battery -> balanced.
info "Configuring automatic power profile switching"

if ! command -v powerprofilesctl >/dev/null 2>&1; then
    warn "powerprofilesctl not found — skipping automatic power profile switching"
else
    sudo tee /usr/local/sbin/auto-power-profile >/dev/null <<'EOFAPP'
#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    logger -t auto-power-profile "$*"
}

if ! command -v powerprofilesctl >/dev/null 2>&1; then
    log "powerprofilesctl not found; skipping"
    exit 0
fi

profile_available() {
    local profile="$1"
    powerprofilesctl list 2>/dev/null | grep -Eq "^[*[:space:]]*${profile}:"
}

on_ac=0

for ps in /sys/class/power_supply/*; do
    [[ -r "$ps/type" ]] || continue

    case "$(<"$ps/type")" in
        Mains|USB|USB_C|USB_PD|USB_PD_DRP)
            if [[ -r "$ps/online" ]] && [[ "$(<"$ps/online")" == "1" ]]; then
                on_ac=1
                break
            fi
            ;;
    esac
done

if [[ "$on_ac" == "1" ]]; then
    if profile_available performance; then
        target="performance"
    else
        target="balanced"
        log "performance profile unavailable; falling back to balanced"
    fi
else
    target="balanced"
fi

current="$(powerprofilesctl get 2>/dev/null || true)"

if [[ "$current" != "$target" ]]; then
    if powerprofilesctl set "$target"; then
        log "set power profile: $target"
    else
        log "failed to set power profile: $target"
        exit 0
    fi
else
    log "power profile already set: $target"
fi
EOFAPP

    sudo chown root:root /usr/local/sbin/auto-power-profile
    sudo chmod 0755 /usr/local/sbin/auto-power-profile

    sudo tee /etc/systemd/system/auto-power-profile.service >/dev/null <<'EOFAPPSVC'
[Unit]
Description=Set power profile based on AC/battery state
Wants=power-profiles-daemon.service
After=power-profiles-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/auto-power-profile

[Install]
WantedBy=multi-user.target
EOFAPPSVC

    sudo tee /etc/udev/rules.d/90-auto-power-profile.rules >/dev/null <<'EOFAPPUDEV'
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="Mains", TAG+="systemd", ENV{SYSTEMD_WANTS}+="auto-power-profile.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="USB", TAG+="systemd", ENV{SYSTEMD_WANTS}+="auto-power-profile.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="USB_C", TAG+="systemd", ENV{SYSTEMD_WANTS}+="auto-power-profile.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="USB_PD", TAG+="systemd", ENV{SYSTEMD_WANTS}+="auto-power-profile.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="USB_PD_DRP", TAG+="systemd", ENV{SYSTEMD_WANTS}+="auto-power-profile.service"
EOFAPPUDEV

    if sudo systemctl daemon-reload &&
       sudo systemctl enable --now power-profiles-daemon.service &&
       sudo systemctl enable --now auto-power-profile.service &&
       sudo udevadm control --reload-rules; then
        sudo udevadm trigger --subsystem-match=power_supply --action=change || true
        success "Automatic power profile switching configured"
    else
        warn "Could not fully enable automatic power profile switching"
    fi
fi

# ── Timezone & locale ─────────────────────────────────────────────────────────
info "Timezone and locale"
sudo timedatectl set-timezone "$TZ"

# Enable English and German UTF-8 locales.
sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo sed -i 's/^# *de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG="$LOCALE"

success "Timezone: $TZ  Locale: $LOCALE"

# ── Flatpak ───────────────────────────────────────────────────────────────────
info "Configuring Flatpak + Flathub"

sudo flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo

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

info "Refreshing installed system Flatpaks"
if sudo flatpak update --system -y --noninteractive; then
    success "System Flatpaks refreshed"
else
    warn "Flatpak refresh failed — continuing"
fi

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

    cat > "$LIBREWOLF_CFG" <<'EOFLW'
// LibreWolf user overrides generated by post-install-debian13.sh

// Enable Firefox Sync by default
// Use defaultPref for soft preferences so GUI changes remain possible.
defaultPref("identity.fxaccounts.enabled", true);

// Home page URL
defaultPref("browser.startup.homepage", "https://start.duckduckgo.com");

// Follow system light/dark theme automatically
defaultPref("extensions.activeThemeID", "default-theme@mozilla.org");
defaultPref("layout.css.prefers-color-scheme.content-override", 2);

// Enhanced Tracking Protection: Strict
pref("browser.contentblocking.category", "strict");
pref("privacy.trackingprotection.enabled", true);
pref("privacy.trackingprotection.pbmode.enabled", true);
pref("privacy.trackingprotection.socialtracking.enabled", true);
pref("privacy.trackingprotection.cryptomining.enabled", true);
pref("privacy.trackingprotection.fingerprinting.enabled", true);
pref("privacy.fingerprintingProtection", true);
pref("privacy.fingerprintingProtection.pbmode", true);
pref("network.cookie.cookieBehavior", 5);
pref("network.cookie.cookieBehavior.pbmode", 5);
pref("privacy.query_stripping.enabled", true);
pref("privacy.query_stripping.enabled.pbmode", true);

// Strict-mode WebCompat exceptions:
// "Fix major site issues" + "Fix minor site issues"
pref("privacy.trackingprotection.allow_list.baseline.enabled", true);
pref("privacy.trackingprotection.allow_list.convenience.enabled", true);

// Keep LibreWolf/Firefox RFP enabled.
// This causes the RFP warning shown in LibreWolf settings.
pref("privacy.resistFingerprinting", true);

// Show Home button in the navigation toolbar
// NOTE: This sets the toolbar layout for fresh/default profiles.
defaultPref("browser.uiCustomization.state", "{\"placements\":{\"widget-overflow-fixed-list\":[],\"unified-extensions-area\":[],\"nav-bar\":[\"back-button\",\"forward-button\",\"stop-reload-button\",\"home-button\",\"urlbar-container\",\"downloads-button\",\"unified-extensions-button\"],\"toolbar-menubar\":[\"menubar-items\"],\"TabsToolbar\":[\"tabbrowser-tabs\",\"new-tab-button\",\"alltabs-button\"],\"PersonalToolbar\":[\"personal-bookmarks\"]},\"seen\":[\"home-button\"],\"dirtyAreaCache\":[\"nav-bar\",\"TabsToolbar\",\"toolbar-menubar\",\"PersonalToolbar\"],\"currentVersion\":20}");

// Restore previous windows and tabs on normal startup
defaultPref("browser.startup.page", 3);

// Restore previous session after crash
defaultPref("browser.sessionstore.resume_from_crash", true);

// Do NOT clear private data on shutdown by default
defaultPref("privacy.sanitize.sanitizeOnShutdown", false);

// Preserve cookies, site data, and login sessions across browser restarts by default
defaultPref("privacy.clearOnShutdown_v2.cookiesAndStorage", false);
defaultPref("privacy.clearOnShutdown.cookies", false);
defaultPref("privacy.clearOnShutdown.sessions", false);
defaultPref("privacy.clearOnShutdown.offlineApps", false);
defaultPref("network.cookie.lifetimePolicy", 0);

// Preserve browsing and download history by default
defaultPref("privacy.clearOnShutdown.history", false);
defaultPref("privacy.clearOnShutdown.downloads", false);

// Preserve more session restore data
// 0 = save all session data; 1 = save only first-party session data.
defaultPref("browser.sessionstore.privacy_level", 1);

// Enable middle-click autoscroll, but prevent middle-click paste by default
defaultPref("middlemouse.paste", false);
defaultPref("general.autoScroll", true);

// Use a stricter autoplay policy by default
defaultPref("media.autoplay.blocking_policy", 2);

// Keep WebGL disabled by default for privacy/fingerprinting resistance.
// Uncomment only if needed for specific websites.
// pref("webgl.disabled", false);
EOFLW

    chmod 0644 "$LIBREWOLF_CFG"
    success "LibreWolf settings written to $LIBREWOLF_CFG"
else
    warn "LibreWolf Flatpak not installed — skipping LibreWolf settings"
fi

# ── .bashrc additions ─────────────────────────────────────────────────────────
info "Patching .bashrc"

BASHRC_MARKER="# >>> post-install additions <<<"

if [[ ! -f "$HOME/.bashrc" ]]; then
    touch "$HOME/.bashrc"
fi

if grep -qF "$BASHRC_MARKER" "$HOME/.bashrc"; then
    warn ".bashrc already patched — skipping"
else
    cat >> "$HOME/.bashrc" <<'EOFBASHRC'

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
EOFBASHRC
    success ".bashrc patched"
fi

# ── GNOME settings ────────────────────────────────────────────────────────────
info "Applying GNOME settings"

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    warn "No active GNOME D-Bus session — skipping gsettings. Run from a GNOME Terminal."
else
    gset org.gnome.desktop.interface color-scheme 'prefer-dark'
    gset org.gnome.settings-daemon.plugins.color night-light-enabled true
    gset org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
    gset org.gnome.desktop.peripherals.touchpad natural-scroll true
    gset org.gnome.desktop.interface show-battery-percentage true
    gset org.gnome.desktop.interface clock-show-seconds true
    gset org.gnome.desktop.interface clock-show-weekday true

    # Power behavior:
    # AC power -> no automatic suspend/hibernate; battery -> suspend after 30 minutes.
    gset org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
    gset org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
    gset org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'suspend'
    gset org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 1800

    # Direct GNOME setting: one global screen blank timeout.
    # GNOME does not expose separate direct AC/battery idle-delay keys here.
    gset org.gnome.desktop.session idle-delay 600

    # Window buttons: minimize, maximize, close on the right side
    gset org.gnome.desktop.wm.preferences button-layout ':minimize,maximize,close'

    # Nautilus: list view and default window size
    gset org.gnome.nautilus.preferences default-folder-viewer 'list-view'
    gset org.gnome.nautilus.window-state initial-size '(1000, 700)'
    gset org.gnome.nautilus.window-state maximized false

    # Keyboard layouts: English US + German + Montenegrin Latin
    gset org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'de'), ('xkb', 'me')]"
    gset org.gnome.desktop.input-sources current 0
    gset org.gnome.desktop.input-sources per-window false

    # GNOME Terminal size only, if the schema exists.
    # Font is deliberately left alone: on this system, forcing JetBrains Mono
    # through the profile caused broken character spacing/rendering.
    if gsettings_has_schema org.gnome.Terminal.ProfilesList; then
        TERM_PROFILE="$(gsettings get org.gnome.Terminal.ProfilesList default | tr -d "'")"

        if [[ -n "$TERM_PROFILE" ]]; then
            TERM_SCHEMA="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${TERM_PROFILE}/"
            gset_path "$TERM_SCHEMA" default-size-columns 120
            gset_path "$TERM_SCHEMA" default-size-rows 31
        else
            warn "Could not detect GNOME Terminal profile — skipping terminal size setting"
        fi
    else
        warn "GNOME Terminal schema not found — skipping terminal size setting"
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
        'code.desktop',
        'org.gnome.Terminal.desktop',
        'org.gnome.gedit.desktop',
        'org.gnome.Boxes.desktop',
        'com.mattjakeman.ExtensionManager.desktop',
        'io.missioncenter.MissionCenter.desktop'
    ]"

    gset org.gnome.shell favorite-apps "$DASH_FAVORITES"
    success "Dash updated"
else
    warn "No active GNOME D-Bus session — skipping Dash pinning"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
info "Enabling unattended upgrades"
apt_run install -y unattended-upgrades apt-listchanges

sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOFAUTOUP'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOFAUTOUP

sudo tee /etc/apt/apt.conf.d/52unattended-local >/dev/null <<'EOFUNATTENDED'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOFUNATTENDED

success "Unattended upgrades configured using Debian defaults, no auto-reboot"

# ── Final cleanup ─────────────────────────────────────────────────────────────
info "Cleaning up"
apt_run autoremove -y
apt_run clean

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
printf '      distrobox create --name deb-1 --image debian:trixie\n'
printf '  • Battery health charging threshold enabled if supported by hardware.\n'
printf '  • Power profile: performance on AC, balanced on battery if supported.\n'
printf '  • Power: no suspend on AC; suspend after 30 min on battery.\n'
printf '  • Screen blank: direct GNOME global idle-delay set to 10 min.\n'
printf '  • Open Timeshift and configure snapshots manually.\n'
printf '  • You will be prompted to confirm reboot.\n'
printf '  ────────────────────────────────────────\n'
printf '\n'

# ── Final reboot ──────────────────────────────────────────────────────────────
info "Final reboot"
info "System should reboot to apply kernel, firmware, Flatpak, GNOME, and package changes."

sync

if [[ -t 0 ]]; then
    printf '\nPress Enter to reboot now, or Ctrl+C to cancel... '
    read -r _
    sudo systemctl reboot
else
    warn "No interactive terminal detected — reboot skipped."
    warn "Please reboot manually."
fi
