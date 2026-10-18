#!/usr/bin/env bash
# Cross-compile the linux-surface Surface Pro X kernel on an x86_64 Fedora
# host and package it as an aarch64 RPM (kernel-spx).
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

require_cmds git curl make gcc flex bison bc perl rpmbuild rpmsign gpg \
    aarch64-linux-gnu-gcc aarch64-linux-gnu-strip

SRC="$WORK_DIR/kernel-src"
BUILD="$WORK_DIR/kernel-build"
STAGE="$WORK_DIR/kernel-stage"
CFG="$WORK_DIR/kernel-config"
JOBS="${JOBS:-$(nproc)}"
KMAKE=(make -C "$SRC" O="$BUILD" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
       LOCALVERSION="-${KERNEL_PKG_RELEASE}.spx.aarch64")

mkdir -p "$WORK_DIR" "$RPM_DIR" "$CFG"

msg "Fetching kernel source ($KERNEL_COMMIT)"
if [ ! -d "$SRC/.git" ]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$KERNEL_REPO"
fi
if ! git -C "$SRC" cat-file -e "$KERNEL_COMMIT^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch --depth 1 origin "$KERNEL_COMMIT"
fi
# Start from a clean tree every time so patches apply exactly once.
git -C "$SRC" checkout -q --force --detach "$KERNEL_COMMIT"
git -C "$SRC" clean -q -fdx

shopt -s nullglob
PATCHES=("$KIT_DIR"/kernel/patches/*.patch)
shopt -u nullglob
for p in "${PATCHES[@]}"; do
    msg2 "applying $(basename "$p")"
    git -C "$SRC" apply --whitespace=nowarn "$p" || die "patch failed: $p"
done

msg "Preparing configuration"
fetch_verified "$BASE_CONFIG_URL" "$CFG/base.config" "$BASE_CONFIG_SHA256"
fetch_verified "$SPX_CONFIG_URL" "$CFG/spx.config" "$SPX_CONFIG_SHA256"
mkdir -p "$BUILD"
(cd "$BUILD" && ARCH=arm64 "$SRC/scripts/kconfig/merge_config.sh" -m -O "$BUILD" \
    "$CFG/base.config" "$CFG/spx.config" \
    "$KIT_DIR/kernel/overrides.config" "$KIT_DIR/kernel/fedora.config" >/dev/null)
"${KMAKE[@]}" olddefconfig >/dev/null

# Fail early if a setting the kit relies on did not survive olddefconfig.
for opt in SECURITY_SELINUX=y BTRFS_FS=y BLK_DEV_NVME=y PCIE_QCOM=y \
           QCOM_PD_MAPPER=m DRM_MSM=m ATH10K_SNOC=m SURFACE_AGGREGATOR=m; do
    grep -q "^CONFIG_${opt}\$" "$BUILD/.config" || die "CONFIG_${opt} missing from final config"
done

KREL="$("${KMAKE[@]}" -s kernelrelease)"
[ "$KREL" = "$KERNEL_RELEASE_STRING" ] || die "unexpected kernel release '$KREL' (wanted $KERNEL_RELEASE_STRING)"

msg "Building kernel $KREL with $JOBS jobs (this takes a while)"
"${KMAKE[@]}" -j"$JOBS" Image modules dtbs

msg "Staging files"
rm -rf "$STAGE"
MODDIR="$STAGE/usr/lib/modules/$KREL"
"${KMAKE[@]}" INSTALL_MOD_PATH="$STAGE/usr" INSTALL_MOD_STRIP=1 DEPMOD=true modules_install >/dev/null
"${KMAKE[@]}" INSTALL_DTBS_PATH="$MODDIR/dtb" dtbs_install >/dev/null
rm -f "$MODDIR/build" "$MODDIR/source"
install -m644 "$BUILD/arch/arm64/boot/Image" "$MODDIR/vmlinuz"
install -m644 "$BUILD/System.map" "$MODDIR/System.map"
install -m644 "$BUILD/.config" "$MODDIR/config"
[ -f "$MODDIR/dtb/$SPX_DTB" ] || die "$SPX_DTB was not built"

msg "Packaging kernel-spx RPM"
TOP="$WORK_DIR/rpmbuild"
rm -rf "$TOP"
mkdir -p "$TOP/SOURCES"
tar -C "$STAGE" -cf "$TOP/SOURCES/kernel-spx-stage.tar" .
rpmbuild -bb --target aarch64-linux \
    --define "_topdir $TOP" \
    --define "kver $KREL" \
    --define "kversion $KERNEL_VERSION" \
    --define "krelease $KERNEL_PKG_RELEASE" \
    --define "kcommit $KERNEL_COMMIT" \
    "$KIT_DIR/kernel/kernel-spx.spec"
find "$TOP/RPMS" -name '*.rpm' -exec cp -t "$RPM_DIR" {} +
sign_rpms "$RPM_DIR"/kernel-spx-"$KERNEL_VERSION"-*.rpm
msg "Done: $(ls "$RPM_DIR"/kernel-spx-"$KERNEL_VERSION"-*.rpm)"
