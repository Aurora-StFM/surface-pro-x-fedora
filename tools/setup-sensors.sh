#!/usr/bin/env bash
# Set up the Surface Pro X motion sensors (accelerometer, magnetometer) on
# Fedora: sensor DSP firmware and configuration from Windows, hexagonrpcd,
# libssc, iio-sensor-proxy with libssc support, and the services that start
# them at boot. Gives KDE automatic screen rotation.
#
# Run ON THE SURFACE as your normal user (it uses sudo where needed):
#   ./setup-sensors.sh /run/media/$USER/<stick>/spx-windows-drivers
#
# The argument is the folder of Windows driver packages copied with the
# README's "Copy files from Windows" step. It must contain
# surfaceprox_subextscss.inf_arm64_* (qcslpi8180.mbn) and
# surfaceprox_sensorsconfig.inf_arm64_* (the sensor JSON configuration).
#
# Needs a kernel-spx with the SLPI device tree patch (0004) and
# CONFIG_QCOM_FASTRPC (kernel-spx 6.18.3-7 or later from this kit, or the
# test DTB from docs/hardware-findings.md).
#
# Everything built from source goes to /usr/local and does not touch Fedora's
# packages. Undo with: ./setup-sensors.sh --remove
set -euo pipefail

FW_DIR=/usr/lib/firmware/qcom/msft/surface/pro-x-sq2
ROOT=/usr/share/qcom/sc8180x/Microsoft/SurfaceProX
SRC_DIR="${SRC_DIR:-$HOME/.cache/surface-pro-x-sensors}"
UDEV_RULE=/etc/udev/rules.d/81-surface-pro-x-ssc.rules
ISP_DROPIN=/etc/systemd/system/iio-sensor-proxy.service.d/ssc.conf
SERVICE=/etc/systemd/system/spx-sensors.service

HEXAGONRPC_REPO=https://github.com/linux-msm/hexagonrpc
LIBSSC_REPO=https://codeberg.org/DylanVanAssche/libssc
ISP_REPO=https://gitlab.freedesktop.org/hadess/iio-sensor-proxy.git

msg() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--remove" ]; then
    msg "Removing the sensor setup"
    sudo systemctl disable --now spx-sensors.service 2>/dev/null || :
    sudo rm -f "$SERVICE" "$UDEV_RULE" "$ISP_DROPIN" /usr/local/libexec/iio-sensor-proxy
    sudo systemctl daemon-reload
    sudo udevadm control --reload
    sudo systemctl restart iio-sensor-proxy 2>/dev/null || :
    echo "Left in place: $ROOT, $FW_DIR/qcslpi8180.mbn and the /usr/local builds of hexagonrpc and libssc."
    exit 0
fi

[ $# -eq 1 ] || die "usage: $0 <spx-windows-drivers folder> | --remove"
WIN="${1%/}"
[ "$(id -u)" -ne 0 ] || die "run as your normal user, not with sudo"

SLPI_PKG="$(ls -d "$WIN"/surfaceprox_subextscss.inf_arm64_* 2>/dev/null | head -n 1)"
CFG_PKG="$(ls -d "$WIN"/surfaceprox_sensorsconfig.inf_arm64_* 2>/dev/null | head -n 1)"
[ -f "$SLPI_PKG/qcslpi8180.mbn" ] || die "qcslpi8180.mbn not found under $WIN/surfaceprox_subextscss.inf_arm64_*"
[ -d "$CFG_PKG" ] || die "sensor configuration not found under $WIN/surfaceprox_sensorsconfig.inf_arm64_*"

if [ ! -d /sys/firmware/devicetree/base/soc@0/remoteproc@2400000 ]; then
    echo "warning: the running device tree has no sensor DSP (SLPI) node."
    echo "         Install a kernel-spx with patch 0004, then run this again."
fi

msg "Installing build dependencies"
sudo dnf install -y git meson ninja-build gcc pkgconf glib2-devel libqmi-devel \
    protobuf-c-devel protobuf-c-compiler python3-devel libgudev-devel \
    polkit-devel systemd-devel

msg "Installing the sensor DSP firmware and configuration from Windows"
sudo install -Dm0644 "$SLPI_PKG/qcslpi8180.mbn" "$FW_DIR/qcslpi8180.mbn"
sudo mkdir -p "$ROOT/sensors/config" "$ROOT/sensors/registry" "$ROOT/socinfo"
sudo cp "$CFG_PKG"/*.json "$CFG_PKG"/config_list.txt "$ROOT/sensors/config/"
for f in hw_platform platform_subtype platform_subtype_id platform_version revision soc_id; do
    sudo cp "$CFG_PKG/$f" "$ROOT/socinfo/"
done

fetch() { # url dir
    if [ -d "$2/.git" ]; then git -C "$2" pull -q --ff-only; else git clone -q "$1" "$2"; fi
}
mkdir -p "$SRC_DIR"

msg "Building hexagonrpc"
fetch "$HEXAGONRPC_REPO" "$SRC_DIR/hexagonrpc"
(cd "$SRC_DIR/hexagonrpc" && rm -rf build && meson setup -q build && ninja -C build && sudo ninja -C build install)
echo /usr/local/lib64 | sudo tee /etc/ld.so.conf.d/usr-local.conf >/dev/null
sudo ldconfig

msg "Building libssc"
fetch "$LIBSSC_REPO" "$SRC_DIR/libssc"
(cd "$SRC_DIR/libssc" && rm -rf build && meson setup -q build && ninja -C build && sudo ninja -C build install)
sudo ldconfig

msg "Building iio-sensor-proxy with libssc support"
fetch "$ISP_REPO" "$SRC_DIR/iio-sensor-proxy"
(cd "$SRC_DIR/iio-sensor-proxy" && rm -rf build &&
    PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig meson setup -q build -Dssc-support=enabled &&
    ninja -C build)
sudo install -Dm0755 "$SRC_DIR/iio-sensor-proxy/build/src/iio-sensor-proxy" /usr/local/libexec/iio-sensor-proxy

msg "Installing udev rule and services"
# Accelerometer only: with the compass enabled as well, the accelerometer stops
# delivering data. The SSC reports Android-convention axes; the mount matrix
# converts them to what iio-sensor-proxy expects (verified on an SQ1).
sudo tee "$UDEV_RULE" >/dev/null <<'EOF'
ACTION!="remove", SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", ENV{IIO_SENSOR_PROXY_TYPE}="ssc-accel", ENV{ACCEL_MOUNT_MATRIX}="-1, 0, 0; 0, -1, 0; 0, 0, -1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="iio-sensor-proxy.service"
EOF

# Fedora's unit only allows AF_UNIX/AF_NETLINK; libssc needs QRTR.
sudo mkdir -p "$(dirname "$ISP_DROPIN")"
sudo tee "$ISP_DROPIN" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/libexec/iio-sensor-proxy
RestrictAddressFamilies=AF_UNIX AF_LOCAL AF_NETLINK AF_QIPCRTR
EOF

sudo tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=Surface Pro X sensor DSP (SLPI) and hexagonrpcd
After=local-fs.target

[Service]
Type=simple
ExecStartPre=/usr/sbin/modprobe fastrpc
ExecStartPre=/bin/sh -c 'for r in /sys/class/remoteproc/*; do [ "\$(cat \$r/name)" = slpi ] && [ "\$(cat \$r/state)" != running ] && echo start > \$r/state; done; for i in \$(seq 1 40); do [ -e /dev/fastrpc-sdsp ] && exit 0; sleep 0.5; done; exit 1'
ExecStart=/usr/local/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R $ROOT
# iio-sensor-proxy may have probed before the DSP had its configuration.
ExecStartPost=/bin/sh -c 'sleep 8; systemctl --no-block restart iio-sensor-proxy.service'
# hexagonrpcd logs every refused registry write (hundreds of lines per boot).
StandardOutput=null
StandardError=null
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo udevadm control --reload
sudo systemctl enable spx-sensors.service

msg "Done"
echo "Reboot. About 15 seconds after login, KDE rotates the screen automatically"
echo "(System Settings > Display > Orientation: Automatic)."
echo "Check with: systemctl status spx-sensors iio-sensor-proxy; monitor-sensor"
