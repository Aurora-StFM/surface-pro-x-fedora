#!/usr/bin/env bash
# Turn the official Fedora KDE aarch64 disk image into a Surface Pro X image:
# install kernel-spx, firmware and support packages, remove Fedora's stock
# kernel (it has no Surface Pro X device tree) and keep dnf from bringing it
# back.
#
# Usage: sudo image/build-image.sh [--image Fedora-KDE-Desktop-Disk-...raw.xz]
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

require_root
require_cmds curl xz losetup sfdisk partx blkid mount btrfs chroot sha256sum gpgv

SRC_IMAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image) SRC_IMAGE="$(realpath "$2")"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

shopt -s nullglob
RPMS=("$RPM_DIR"/kernel-spx-*.aarch64.rpm "$RPM_DIR"/surface-pro-x-firmware-*.noarch.rpm "$RPM_DIR"/surface-pro-x-support-*.noarch.rpm)
shopt -u nullglob
[ ${#RPMS[@]} -ge 3 ] || die "build the packages first (./build.sh kernel firmware support)"
[ -f "$SIGN_PUBKEY" ] || die "signing key $SIGN_PUBKEY missing"

# ---- qemu for running aarch64 tools in the chroot -------------------------
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    systemctl restart systemd-binfmt 2>/dev/null || true
fi
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die "qemu-aarch64 binfmt handler not registered (install qemu-user-static-aarch64)"
grep -q '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || die "qemu-aarch64 binfmt handler lacks the F flag; use Fedora's qemu-user-static package"

DL="$OUT_DIR/downloads"
mkdir -p "$DL"

# ---- download and verify the Fedora image --------------------------------
if [ -z "$SRC_IMAGE" ]; then
    BASE="$FEDORA_MIRROR/releases/$FEDORA_RELEASE/$FEDORA_EDITION/aarch64/images"
    msg "Looking up Fedora $FEDORA_RELEASE $FEDORA_EDITION aarch64 image"
    listing="$(curl -fsSL "$BASE/")" || die "cannot list $BASE (is Fedora $FEDORA_RELEASE released?)"
    name="$(grep -o "Fedora-${FEDORA_EDITION}-Desktop-Disk-${FEDORA_RELEASE}-[0-9.]*\.aarch64\.raw\.xz" <<<"$listing" | sort -uV | tail -n1)"
    csum="$(grep -o "Fedora-${FEDORA_EDITION}-${FEDORA_RELEASE}-[0-9.]*-aarch64-CHECKSUM" <<<"$listing" | sort -uV | tail -n1)"
    [ -n "$name" ] && [ -n "$csum" ] || die "no disk image found in $BASE"
    SRC_IMAGE="$DL/$name"
    [ -f "$SRC_IMAGE" ] || curl -fL --retry 3 -o "$SRC_IMAGE.part" "$BASE/$name"
    [ -f "$SRC_IMAGE.part" ] && mv "$SRC_IMAGE.part" "$SRC_IMAGE"
    curl -fsSL -o "$DL/$csum" "$BASE/$csum"

    keyfile="/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${FEDORA_RELEASE}-primary"
    if [ -f "$keyfile" ]; then
        gpg --batch --yes --dearmor -o "$DL/fedora.gpg" "$keyfile"
        gpgv --keyring "$DL/fedora.gpg" "$DL/$csum" >/dev/null 2>&1 \
            || die "GPG signature of $csum is not valid"
        msg2 "CHECKSUM signature OK"
    else
        warn "$keyfile not found, skipping GPG check of the CHECKSUM file (install fedora-gpg-keys)"
    fi
    (cd "$DL" && grep -E "^SHA256 \($name\)" "$csum" | sha256sum -c --quiet -) \
        || die "SHA256 mismatch for $name"
    msg2 "image checksum OK"
fi

OUT_IMAGE="$OUT_DIR/Fedora-${FEDORA_EDITION}-SurfaceProX-${FEDORA_RELEASE}.raw"
msg "Unpacking to $(basename "$OUT_IMAGE")"
case "$SRC_IMAGE" in
    *.xz) xz -dc -T0 "$SRC_IMAGE" > "$OUT_IMAGE" ;;
    *) cp --sparse=always "$SRC_IMAGE" "$OUT_IMAGE" ;;
esac
truncate -s "+${IMAGE_EXTRA_GB}G" "$OUT_IMAGE"

MNT="$WORK_DIR/image-root"
LOOP=""
cleanup() {
    set +e
    if [ -n "${RESOLV_BACKUP:-}" ]; then
        rm -f "$MNT/etc/resolv.conf"
        [ -e "$RESOLV_BACKUP" ] || [ -L "$RESOLV_BACKUP" ] && cp -a "$RESOLV_BACKUP" "$MNT/etc/resolv.conf"
        RESOLV_BACKUP=""
    fi
    if [ -n "${NSS_BACKUP:-}" ] && [ -f "$NSS_BACKUP" ]; then
        cp -a "$NSS_BACKUP" "$MNT/etc/nsswitch.conf"
        NSS_BACKUP=""
    fi
    if [ -n "${MACHINE_ID_BACKUP:-}" ]; then
        if [ -f "$MACHINE_ID_BACKUP" ]; then
            cp "$MACHINE_ID_BACKUP" "$MNT/etc/machine-id"
        else
            rm -f "$MNT/etc/machine-id"
        fi
        MACHINE_ID_BACKUP=""
    fi
    umount -R "$MNT" 2>/dev/null
    [ -n "$LOOP" ] && losetup -d "$LOOP"
}
trap cleanup EXIT

LOOP="$(losetup -fP --show "$OUT_IMAGE")"
sfdisk --relocate gpt-bak-std "$LOOP" >/dev/null 2>&1 || true

# Identify partitions by filesystem type.
ESP=""; BOOT=""; ROOT=""; ROOT_NUM=""
for p in "$LOOP"p*; do
    case "$(blkid -s TYPE -o value "$p" 2>/dev/null)" in
        vfat) ESP="$p" ;;
        ext4|xfs) BOOT="$p" ;;
        btrfs) ROOT="$p"; ROOT_NUM="${p##*p}" ;;
    esac
done
[ -n "$ESP" ] && [ -n "$BOOT" ] && [ -n "$ROOT" ] || die "unexpected partition layout in $(basename "$SRC_IMAGE")"

msg "Growing root partition by ${IMAGE_EXTRA_GB} GiB"
echo ", +" | sfdisk -q --no-reread -N "$ROOT_NUM" "$LOOP"
partx -u "$LOOP"

mkdir -p "$MNT"
mount -o subvol=root "$ROOT" "$MNT"
[ -f "$MNT/etc/os-release" ] || die "root subvolume does not look like Fedora"
btrfs -q filesystem resize max "$MNT"
mount "$BOOT" "$MNT/boot"
mount "$ESP" "$MNT/boot/efi"
for d in dev dev/pts proc sys; do mount --bind "/$d" "$MNT/$d"; done
mount -t tmpfs tmpfs "$MNT/run"
mkdir -p "$MNT/run/systemd/resolve"
cp -L /etc/resolv.conf "$MNT/run/systemd/resolve/stub-resolv.conf"
cp -L /etc/resolv.conf "$MNT/run/systemd/resolve/resolv.conf"
# The image's /etc/resolv.conf may be an empty file or point somewhere that
# doesn't exist in the chroot. Swap in the host's copy and restore it later.
RESOLV_BACKUP="$WORK_DIR/resolv.conf.orig"
rm -f "$RESOLV_BACKUP"
if [ -e "$MNT/etc/resolv.conf" ] || [ -L "$MNT/etc/resolv.conf" ]; then
    cp -a "$MNT/etc/resolv.conf" "$RESOLV_BACKUP"
fi
rm -f "$MNT/etc/resolv.conf"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
# Point name lookups at plain DNS while in the chroot (systemd-resolved is not running).
NSS_BACKUP="$WORK_DIR/nsswitch.conf.orig"
cp -a "$MNT/etc/nsswitch.conf" "$NSS_BACKUP"
sed -i 's/^hosts:.*/hosts:      files dns/' "$MNT/etc/nsswitch.conf"
chroot "$MNT" getent hosts mirrors.fedoraproject.org >/dev/null \
    || die "DNS does not work inside the image. Check that 'getent hosts mirrors.fedoraproject.org' works in WSL itself."

# kernel-install names boot entries after the machine id, which Fedora images
# ship empty. Borrow the id the existing entries use for the duration.
MACHINE_ID_BACKUP="$WORK_DIR/machine-id.orig"
rm -f "$MACHINE_ID_BACKUP"
[ -f "$MNT/etc/machine-id" ] && cp "$MNT/etc/machine-id" "$MACHINE_ID_BACKUP"
first_entry="$(find "$MNT/boot/loader/entries" -name '*.conf' ! -name '*rescue*' | sort | head -n1)"
[ -n "$first_entry" ] || die "no BLS entries in the image"
entry_id="$(basename "$first_entry" | grep -oE '^[0-9a-f]{32}')" || true
[ -n "$entry_id" ] || entry_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
echo "$entry_id" > "$MNT/etc/machine-id"

# Kernel command line for new entries: the image's own options plus ours.
opts="$(awk '$1 == "options" { $1 = ""; sub(/^ /, ""); print; exit }' "$first_entry")"
for a in $SPX_KERNEL_ARGS; do
    case " $opts " in *" $a "*) ;; *) opts="$opts $a" ;; esac
done
echo "$opts" > "$MNT/etc/kernel/cmdline"
mkdir -p "$MNT/etc/surface-pro-x"
tr ' ' '\n' <<<"$SPX_KERNEL_ARGS" > "$MNT/etc/surface-pro-x/kernel-args"
msg2 "kernel command line: $opts"

STAGE="$MNT/var/tmp/spx-rpms"
mkdir -p "$STAGE"
cp "${RPMS[@]}" "$SIGN_PUBKEY" "$STAGE/"
install -Dm644 "$SIGN_PUBKEY" "$MNT/etc/pki/rpm-gpg/RPM-GPG-KEY-surface-pro-x-local"

msg "Installing packages in the image (runs under qemu, be patient)"
chroot "$MNT" /usr/bin/bash -euo pipefail -c '
    rpmkeys --import /etc/pki/rpm-gpg/RPM-GPG-KEY-surface-pro-x-local
    dnf -y install /var/tmp/spx-rpms/*.rpm

    # Remove the stock kernel: it cannot boot this device.
    stock="$(rpm -qa --qf "%{NAME}\n" | grep -xE "kernel(-core|-modules|-modules-core|-modules-extra|-uki-virt)?" | sort -u || true)"
    if [ -n "$stock" ]; then
        echo "  -> removing: $(echo $stock)"
        rpm -e --nodeps $stock
    fi
    # Rescue entries use the stock kernel and cannot boot this device.
    rm -f /boot/vmlinuz-0-rescue-* /boot/initramfs-0-rescue-* /boot/loader/entries/*-0-rescue*.conf

    # Never pull it back in on updates.
    conf=/etc/dnf/dnf.conf
    grep -q "^\[main\]" "$conf" || echo "[main]" >> "$conf"
    sed -i "/^excludepkgs=/d" "$conf"
    sed -i "/^\[main\]/a excludepkgs=kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kernel-uki-virt" "$conf"

    kver="$(ls /usr/lib/modules | grep "\.spx\." | sort -V | tail -n1)"
    grubby --set-default "/boot/vmlinuz-$kver" >/dev/null
    grub2-editenv - unset menu_auto_hide || true
    systemctl enable rmtfs.service tqftpserv.service
    touch /.autorelabel
    rm -rf /var/tmp/spx-rpms
    dnf clean all >/dev/null
'

msg "Checking the result"
# If a check below fails, don't leave a broken image behind that looks usable.
fail_image() {
    mv -f "$OUT_IMAGE" "$OUT_IMAGE.broken" 2>/dev/null
    die "$1 (image renamed to $(basename "$OUT_IMAGE").broken, don't flash it)"
}
kver="$(find "$MNT/usr/lib/modules" -mindepth 1 -maxdepth 1 -name '*.spx.*' -printf '%f\n' | sort -V | tail -n1)"
entry="$(ls "$MNT"/boot/loader/entries/*-"$kver".conf 2>/dev/null | head -n1)"
[ -n "$entry" ] || fail_image "no boot entry for $kver"
grep -q '^devicetree .*sc8180x-surface-pro-x.dtb' "$entry" || fail_image "devicetree line missing in $entry"
# GRUB's BLS parser stops at the first blank line, hiding anything after it.
! grep -q '^[[:space:]]*$' "$entry" || fail_image "blank line in $entry (GRUB would ignore the lines after it)"
for a in $SPX_KERNEL_ARGS; do grep -q "^options.* $a" "$entry" || fail_image "'$a' missing in $entry"; done
dtb_path="$(awk '$1 == "devicetree" { print $2 }' "$entry")"
[ -f "$MNT/boot$dtb_path" ] || fail_image "DTB $dtb_path not found on /boot"
[ -f "$MNT/boot/initramfs-$kver.img" ] || fail_image "initramfs for $kver missing"
[ -f "$MNT/boot/vmlinuz-$kver" ] || fail_image "kernel image for $kver missing"
for k in "$MNT"/boot/vmlinuz-*; do
    case "$k" in *.spx.*|*rescue*) ;; *) warn "a non-Surface kernel is still in /boot: $(basename "$k")" ;; esac
done
msg2 "boot entry:"
sed 's/^/      /' "$entry"

cleanup
trap - EXIT
msg "Image ready: $OUT_IMAGE"
echo "    Write it to a USB drive (16 GB or larger) with Fedora Media Writer, Rufus (DD mode) or dd."
