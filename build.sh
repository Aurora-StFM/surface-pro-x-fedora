#!/usr/bin/env bash
# Surface Pro X Fedora kit: build entry point.
#
#   ./build.sh deps                       install build dependencies (sudo)
#   ./build.sh kernel                     cross-compile kernel-spx
#   ./build.sh firmware [--from-dir DIR]  package firmware (repo or your Windows)
#   ./build.sh support                    package surface-pro-x-support
#   sudo ./build.sh image [--image FILE]  build the USB disk image
#   sudo ./build.sh all                   everything above in order
#
# Run on Fedora: native, or Fedora under WSL2 on Windows.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

DEPS=(
    git curl make gcc flex bison bc perl openssl openssl-devel elfutils-libelf-devel
    dwarves rsync python3 gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
    rpm-build rpm-sign gnupg2 xz util-linux btrfs-progs e2fsprogs dosfstools
    qemu-user-static-aarch64 fedora-gpg-keys cpio zstd
)

# Build steps that don't need root drop privileges back to the invoking user.
as_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" --preserve-env=OUT_DIR,JOBS,FEDORA_RELEASE "$@"
    else
        "$@"
    fi
}

step="${1:-}"
[ $# -gt 0 ] && shift
case "$step" in
    deps)
        require_fedora_host
        sudo dnf install -y "${DEPS[@]}"
        sudo systemctl restart systemd-binfmt 2>/dev/null || true
        ;;
    kernel)   require_fedora_host; as_user "$KIT_DIR/kernel/build-kernel.sh" "$@" ;;
    firmware) require_fedora_host; as_user "$KIT_DIR/firmware/build-firmware.sh" "$@" ;;
    support)  require_fedora_host; as_user "$KIT_DIR/support/build-support.sh" "$@" ;;
    image)    require_fedora_host; "$KIT_DIR/image/build-image.sh" "$@" ;;
    all)
        require_fedora_host
        require_root
        export OUT_DIR
        as_user mkdir -p "$OUT_DIR"
        as_user "$KIT_DIR/kernel/build-kernel.sh"
        as_user "$KIT_DIR/firmware/build-firmware.sh"
        as_user "$KIT_DIR/support/build-support.sh"
        "$KIT_DIR/image/build-image.sh"
        ;;
    *)
        sed -n '2,12p' "$0"
        exit 1
        ;;
esac
