#!/usr/bin/env bash
# Install iptsd, the touch and pen processing daemon, on the Surface Pro X.
#
# Without iptsd the touchscreen runs in its single-touch fallback mode. iptsd
# switches it to multitouch mode, turns the raw touch heatmap into finger
# contacts (gestures, pinch-to-zoom, palm rejection) and handles the pen.
#
# Run ON THE SURFACE as your normal user (it uses sudo where needed):
#   ./setup-touch.sh            install (Fedora package if there is one,
#                               otherwise build an RPM from upstream)
#   ./setup-touch.sh --check    only show the touchscreen state
#
# The RPM it builds is kept in ~/rpmbuild-iptsd/RPMS/aarch64/ and can be
# removed again with: sudo dnf remove iptsd
set -euo pipefail

IPTSD_VERSION="${IPTSD_VERSION:-3.1.1}"
IPTSD_URL="https://github.com/linux-surface/iptsd/archive/refs/tags/v$IPTSD_VERSION.tar.gz"
TOP="${TOP:-$HOME/rpmbuild-iptsd}"

msg() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

check() {
    msg "Touchscreen state"
    echo "spi_hid driver:  $(lsmod | grep -q '^spi_hid' && echo loaded || echo 'NOT loaded')"
    local found=0 h
    for h in /sys/class/hidraw/hidraw*; do
        [ -e "$h" ] || continue
        local uevent; uevent="$(cat "$h/device/uevent" 2>/dev/null)"
        echo "$(basename "$h"): $(grep -E '^HID_(ID|NAME)=' <<<"$uevent" | tr '\n' ' ')"
        case "$(readlink -f "$h/device")" in *spi*) found=1 ;; esac
    done
    [ "$found" -eq 1 ] || echo "warning: no hidraw device on the SPI bus (the touchscreen)"
    local r
    for r in /sys/bus/spi/devices/*/ready; do
        [ -r "$r" ] && echo "spi-hid $(basename "$(dirname "$r")"): $(cat "$r")"
    done
    echo "iptsd: $(rpm -q iptsd 2>/dev/null || echo 'not installed')"
    systemctl list-units --no-pager --all 'iptsd@*' 'surface-pro-x-touch@*' || :
}

[ "$(id -u)" -ne 0 ] || die "run as your normal user, not with sudo"
if [ "${1:-}" = "--check" ]; then check; exit 0; fi
[ $# -eq 0 ] || die "usage: $0 [--check]"

if rpm -q iptsd >/dev/null 2>&1; then
    msg "iptsd is already installed: $(rpm -q iptsd)"
elif dnf -q list --available iptsd >/dev/null 2>&1; then
    msg "Installing iptsd from the Fedora repositories"
    sudo dnf install -y iptsd
else
    msg "Building iptsd $IPTSD_VERSION as an RPM (a few minutes)"
    sudo dnf install -y rpm-build dnf-plugins-core curl
    rm -rf "$TOP"
    mkdir -p "$TOP/SOURCES" "$TOP/SPECS"
    curl -fL --retry 3 -o "$TOP/SOURCES/iptsd-$IPTSD_VERSION.tar.gz" "$IPTSD_URL"
    # Upstream's spec is an rpkg template; point its Source at the tarball.
    tar -xzOf "$TOP/SOURCES/iptsd-$IPTSD_VERSION.tar.gz" "iptsd-$IPTSD_VERSION/iptsd.spec" |
        sed 's|^Source:.*|Source: iptsd-%{version}.tar.gz|' > "$TOP/SPECS/iptsd.spec"
    sudo dnf builddep -y "$TOP/SPECS/iptsd.spec"
    rpmbuild -bb --nocheck --define "_topdir $TOP" "$TOP/SPECS/iptsd.spec"
    sudo dnf install -y "$TOP"/RPMS/*/iptsd-"$IPTSD_VERSION"-*.rpm
fi

FILES="$(cd "$(dirname "$0")/../support/files" 2>/dev/null && pwd)" || :
if [ -e /usr/lib/systemd/system/surface-pro-x-touch@.service ]; then
    msg "Touch integration provided by surface-pro-x-support; removing local copies"
    sudo rm -f /etc/udev/rules.d/68-surface-pro-x-touch.rules \
        /etc/systemd/system/surface-pro-x-touch@.service \
        /usr/local/libexec/surface-pro-x-touch
else
    [ -f "$FILES/surface-pro-x-touch@.service" ] ||
        die "run this from the kit (tools/setup-touch.sh), or install surface-pro-x-support 1.8"
    msg "Installing the touch integration (surface-pro-x-support 1.8 ships it too)"
    sudo install -Dm0644 "$FILES/68-surface-pro-x-touch.rules" /etc/udev/rules.d/68-surface-pro-x-touch.rules
    sudo install -Dm0755 "$FILES/surface-pro-x-touch" /usr/local/libexec/surface-pro-x-touch
    sed 's|/usr/libexec/surface-pro-x/surface-pro-x-touch|/usr/local/libexec/surface-pro-x-touch|' \
        "$FILES/surface-pro-x-touch@.service" |
        sudo tee /etc/systemd/system/surface-pro-x-touch@.service >/dev/null
fi
# Earlier versions of this setup added a restart drop-in to iptsd@.service.
sudo rm -rf /etc/systemd/system/iptsd@.service.d/surface-pro-x.conf

msg "Starting iptsd for the touchscreen"
sudo modprobe uinput
sudo systemctl daemon-reload
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=hidraw --action=add
sudo udevadm trigger --subsystem-match=input --action=change
sleep 4
check

msg "Done"
echo "Log out and back in so KDE drops the single-touch devices, then"
echo "try two-finger scrolling and pinch-to-zoom, and the pen if you have one."
echo "Logs: journalctl -b -u 'surface-pro-x-touch@*'"
