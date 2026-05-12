# Fedora 44 Btrfs Snapshot + Rollback How-To

## 1. Target disk

This how-to uses the following example disk:

```text
/dev/sda
```

On another system, the disk name may be different, for example:

```text
/dev/nvme0n1
/dev/vda
/dev/sdb
```

Check the target disk carefully before partitioning. Selecting the wrong disk can erase the wrong drive.

## 2. Volume / subvolume tree

```text
/dev/sda
├─ /dev/sda1   vfat    ESP       /boot/efi        1 GiB
└─ /dev/sda2   btrfs   FEDORA    top-level        rest of disk
   ├─ root        -> /
   ├─ home        -> /home
   ├─ opt         -> /opt
   ├─ cache       -> /var/cache
   ├─ log         -> /var/log
   ├─ spool       -> /var/spool
   ├─ tmp         -> /var/tmp
   ├─ containers  -> /var/lib/containers
   ├─ flatpak     -> /var/lib/flatpak
   ├─ gdm         -> /var/lib/gdm
   └─ libvirt     -> /var/lib/libvirt
```

No separate `/boot` partition is used. Kernel and initramfs stay inside the Btrfs root, so rollback keeps the system and boot files in sync.

No swap partition is required because Fedora uses ZRAM by default.

## 3. Fedora installation

Boot the Fedora Workstation 44 ISO in UEFI mode.

Start the installer:

```text
Start Fedora Workstation Live
Install Fedora Linux
```

Choose your language and keyboard layout.

At the installation method screen:

```text
Change destination
Select the target disk
Three-dot menu
Launch storage editor
```

For a clean install, create a new GPT partition table:

```text
Three-dot menu beside the disk
Create partition table
GPT
Initialize
```

This erases the selected disk.

### Create EFI partition

```text
Name: ESP
Type: EFI system partition
Mount point: /boot/efi
Size: 1.0737 GB
```

### Create main Btrfs partition

```text
Name: FEDORA
Type: BTRFS
Mount point: empty
Size: remaining space
Encryption: No encryption
```

### Create Btrfs subvolumes

Create these under the Btrfs top-level volume:

```text
root        /
home        /home
opt         /opt
cache       /var/cache
log         /var/log
spool       /var/spool
tmp         /var/tmp
containers  /var/lib/containers
flatpak     /var/lib/flatpak
gdm         /var/lib/gdm
libvirt     /var/lib/libvirt
```

Then continue:

```text
Return to installation
Continue
Install
Reboot
Complete initial Fedora setup
```

## 4. Verify layout after first boot

Open Terminal.

Check the Btrfs filesystem:

```bash
sudo btrfs filesystem show /
```

Check the disk layout:

```bash
lsblk -p /dev/sda
```

List Btrfs subvolumes:

```bash
sudo btrfs subvolume list /
```

Check `/etc/fstab`:

```bash
cat /etc/fstab
```

You may also see this subvolume:

```text
var/lib/machines
```

That is normal. Fedora/systemd can create it automatically.

## 5. Enable Btrfs compression

With custom partitioning, Fedora may not add compression automatically. Add `compress=zstd:1` to all Btrfs entries in `/etc/fstab`:

```bash
sudo sed -i.bkp '/ btrfs / s/subvol=[^ ,]*/&,compress=zstd:1/' /etc/fstab
```

Verify:

```bash
cat /etc/fstab
```

Reboot:

```bash
reboot
```

After reboot, verify compression:

```bash
findmnt -t btrfs -o TARGET,OPTIONS | grep compress
```

Optional recompression of existing data:

```bash
sudo btrfs filesystem defragment -r -v -czstd /
```

```bash
sudo btrfs filesystem defragment -r -v -czstd /home
```

On a fresh install, recompression is usually not necessary.

## 6. Update Fedora

```bash
sudo dnf update -y
```

```bash
reboot
```

## 7. Install Snapper, grub-btrfs, and Btrfs Assistant

Use your fork:

```bash
sudo dnf install git -y
```

```bash
git clone https://github.com/vdarkobar/sysguides-snapper-fedora
```

```bash
cd sysguides-snapper-fedora
```

```bash
chmod +x install.sh
```

```bash
./install.sh
```

This sets up:

```text
Snapper
grub-btrfs
Btrfs Assistant
DNF5 snapshot integration
root snapshot config
home snapshot config
```

## 8. Verify Snapper setup

Check root snapshots:

```bash
snapper ls
```

Check home snapshots:

```bash
snapper -c home ls
```

Check Btrfs subvolumes again:

```bash
sudo btrfs subvolume list /
```

## 9. Test automatic CLI snapshots

Install a test package:

```bash
sudo dnf install htop -y
```

Check that it is installed:

```bash
which htop
```

List snapshots:

```bash
snapper ls
```

Compare pre/post snapshot changes:

```bash
sudo snapper status PRE..POST
```

Example:

```bash
sudo snapper status 1..2
```

Undo the installation:

```bash
sudo snapper undochange PRE..POST
```

Example:

```bash
sudo snapper undochange 1..2
```

Check that `htop` is gone:

```bash
which htop || true
```

Redo the change by reversing the snapshot order:

```bash
sudo snapper undochange POST..PRE
```

Example:

```bash
sudo snapper undochange 2..1
```

Check again:

```bash
which htop
```

## 10. Test GUI snapshots

Install a Fedora RPM package from GNOME Software, for example `gedit`.

Use the Fedora RPM source, not Flatpak. Flatpak apps do not trigger DNF/Snapper pre/post snapshots.

Check package status:

```bash
rpm -q gedit
```

Check snapshots:

```bash
snapper ls
```

Undo the GUI installation:

```bash
sudo snapper undochange PRE..POST
```

If GNOME Software still shows stale package status, log out and log back in.

## 11. Manual root snapshots

Create a pre snapshot:

```bash
sudo snapper create --type pre --print-number --description "Before test"
```

Make your changes.

Create a post snapshot:

```bash
sudo snapper create --type post --pre-number PRE_NUMBER --description "After test"
```

Undo root changes:

```bash
sudo snapper undochange PRE_NUMBER..POST_NUMBER
```

## 12. Manual home snapshots

Create a pre snapshot for `/home`:

```bash
sudo snapper -c home create --type pre --print-number --description "Before home test"
```

Make your changes.

Create a post snapshot for `/home`:

```bash
sudo snapper -c home create --type post --pre-number PRE_NUMBER --description "After home test"
```

Undo home changes:

```bash
sudo snapper -c home undochange PRE_NUMBER..POST_NUMBER
```

## 13. Complete command list

```bash
sudo btrfs filesystem show /
lsblk -p /dev/sda
sudo btrfs subvolume list /
cat /etc/fstab

sudo sed -i.bkp '/ btrfs / s/subvol=[^ ,]*/&,compress=zstd:1/' /etc/fstab
cat /etc/fstab
reboot

findmnt -t btrfs -o TARGET,OPTIONS | grep compress

sudo btrfs filesystem defragment -r -v -czstd /
sudo btrfs filesystem defragment -r -v -czstd /home

sudo dnf update -y
reboot

sudo dnf install git -y
git clone https://github.com/vdarkobar/sysguides-snapper-fedora
cd sysguides-snapper-fedora
chmod +x install.sh
./install.sh

snapper ls
snapper -c home ls
sudo btrfs subvolume list /

sudo dnf install htop -y
which htop
snapper ls
sudo snapper status PRE..POST
sudo snapper undochange PRE..POST
which htop || true
sudo snapper undochange POST..PRE
which htop

rpm -q gedit
snapper ls
sudo snapper undochange PRE..POST

sudo snapper create --type pre --print-number --description "Before test"
sudo snapper create --type post --pre-number PRE_NUMBER --description "After test"
sudo snapper undochange PRE_NUMBER..POST_NUMBER

sudo snapper -c home create --type pre --print-number --description "Before home test"
sudo snapper -c home create --type post --pre-number PRE_NUMBER --description "After home test"
sudo snapper -c home undochange PRE_NUMBER..POST_NUMBER
```
