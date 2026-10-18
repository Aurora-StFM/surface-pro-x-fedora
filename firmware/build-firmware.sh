#!/usr/bin/env bash
# Package the Surface Pro X firmware as a noarch RPM (surface-pro-x-firmware).
#
#   build-firmware.sh                     use the linux-surface aarch64-firmware repo
#   build-firmware.sh --from-dir DIR      use a tree made by aarch64-firmware's
#                                         scripts/getfw.py from your own Windows
#
# Files that only exist for the Surface Pro X go to /usr/lib/firmware.
# Files that Fedora's linux-firmware also ships (ath10k, qca, Adreno) go to
# /usr/lib/firmware/updates, which the kernel searches first. This avoids file
# conflicts with Fedora's packages and still takes priority over them.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

require_cmds git rpmbuild rpmsign gpg

FROM_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from-dir) FROM_DIR="$(realpath "$2")"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

mkdir -p "$WORK_DIR" "$RPM_DIR"

if [ -n "$FROM_DIR" ]; then
    SRC="$FROM_DIR"
    FW_VERSION="$(date +%Y%m%d)"
    FW_SOURCE="getfw.py output from $FROM_DIR"
else
    REPO="$WORK_DIR/aarch64-firmware"
    msg "Fetching firmware repository ($FIRMWARE_COMMIT)"
    if [ ! -d "$REPO/.git" ]; then
        git init -q "$REPO"
        git -C "$REPO" remote add origin "$FIRMWARE_REPO"
    fi
    git -C "$REPO" fetch --depth 1 origin "$FIRMWARE_COMMIT"
    git -C "$REPO" checkout -q --force FETCH_HEAD
    SRC="$REPO/firmware"
    FW_VERSION="$(TZ=UTC git -C "$REPO" show -s --format=%cd --date=format-local:%Y%m%d HEAD)"
    FW_SOURCE="linux-surface/aarch64-firmware@${FIRMWARE_COMMIT:0:12}"
fi

PLAT="qcom/msft/surface/pro-x-sq2"
for f in "$PLAT/qcmpss8180.mbn" "$PLAT/wlanmdsp.mbn" "$PLAT/qcdxkmsuc8180.mbn" \
         "$PLAT/qcadsp8180.mbn" "$PLAT/qccdsp8180.mbn" \
         ath10k/WCN3990/hw1.0/board-2.bin ath10k/WCN3990/hw1.0/firmware-5.bin \
         qcom/a680_sqe.fw qcom/a680_gmu.bin qca/crbtfw21.tlv; do
    [ -e "$SRC/$f" ] || die "firmware file missing: $SRC/$f"
done

msg "Staging firmware ($FW_SOURCE)"
STAGE="$WORK_DIR/firmware-stage"
rm -rf "$STAGE"
FW="$STAGE/usr/lib/firmware"
UPD="$FW/updates"
mkdir -p "$FW/qcom/msft/surface" "$UPD/ath10k/WCN3990/hw1.0" "$UPD/qca" "$UPD/qcom"

cp -a "$SRC/$PLAT" "$FW/qcom/msft/surface/"
cp -a "$SRC"/ath10k/WCN3990/hw1.0/{board-2.bin,firmware-5.bin} "$UPD/ath10k/WCN3990/hw1.0/"
cp -a "$SRC"/qcom/a680_sqe.fw "$SRC"/qcom/a680_gmu.bin "$UPD/qcom/"
[ -d "$SRC/qcom/venus-5.2" ] && cp -a "$SRC/qcom/venus-5.2" "$UPD/qcom/"
# Bluetooth: WCN3991 data plus the crnv01/crbtfw01 links for the misreported chip ID.
cp -a "$SRC"/qca/crbtfw21.tlv "$SRC"/qca/crnv21.* "$UPD/qca/"
(
    cd "$UPD/qca"
    ln -sf crbtfw21.tlv crbtfw01.tlv
    for f in crnv21.*; do ln -sf "$f" "crnv01.${f#crnv21.}"; done
)

msg "Packaging surface-pro-x-firmware RPM"
TOP="$WORK_DIR/rpmbuild-fw"
rm -rf "$TOP"
mkdir -p "$TOP/SOURCES"
tar -C "$STAGE" -cf "$TOP/SOURCES/surface-pro-x-firmware.tar" .
rpmbuild -bb \
    --define "_topdir $TOP" \
    --define "fwversion $FW_VERSION" \
    --define "fwsource $FW_SOURCE" \
    "$KIT_DIR/firmware/surface-pro-x-firmware.spec"
rm -f "$RPM_DIR"/surface-pro-x-firmware-*.rpm
find "$TOP/RPMS" -name '*.rpm' -exec cp -t "$RPM_DIR" {} +
sign_rpms "$RPM_DIR"/surface-pro-x-firmware-*.rpm
msg "Done: $(ls "$RPM_DIR"/surface-pro-x-firmware-*.rpm)"
