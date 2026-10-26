#!/usr/bin/env bash
# Read the Surface Pro X ambient light sensor (AMS TCS3430, i2c-0 0x39) directly,
# to check that it produces data before writing a kernel driver for it.
#
# The device tree currently binds the apds9960 driver to it, which is the wrong
# chip (TCS3430 ID 0xdc). This script unbinds that driver, sets the TCS3430 up
# with datasheet defaults, and prints the four channels once a second.
# Cover and uncover the sensor (top edge, near the front camera) while it runs.
#
# Run ON THE SURFACE:  ./als-test.sh [seconds]     (default 15)
# Rebind the old driver afterwards with a reboot, or:
#   echo 0-0039 | sudo tee /sys/bus/i2c/drivers/apds9960/bind
set -uo pipefail
BUS=0 ADDR=0x39 SECS="${1:-15}"
command -v i2cset >/dev/null || { echo "install i2c-tools: sudo dnf install i2c-tools" >&2; exit 1; }
sudo -v || exit 1

r() { sudo i2cget -f -y $BUS $ADDR "$1"; }
w() { sudo i2cset -f -y $BUS $ADDR "$1" "$2"; }
word() { printf '%d' $(( $(r $(( $1 + 1 ))) << 8 | $(r "$1") )); }

echo "ID $(r 0x92)  REVID $(r 0x91)  (TCS3430: ID 0xdc)"
echo "Before: ENABLE $(r 0x80) ATIME $(r 0x81) CFG1 $(r 0x90) CFG2 $(r 0x9f) CFG3 $(r 0xab) AZ $(r 0xd6) INTENAB $(r 0xdd)"

if [ -e /sys/bus/i2c/drivers/apds9960/0-0039 ]; then
    echo "Unbinding the apds9960 driver"
    echo 0-0039 | sudo tee /sys/bus/i2c/drivers/apds9960/unbind >/dev/null
fi

# Datasheet defaults, then: 16x gain, ~100 ms integration, ALS on.
w 0x80 0x00          # ENABLE: off
w 0x8c 0x00          # PERS
w 0x8d 0x80          # CFG0 (reserved bit 7 = 1)
w 0x9f 0x04          # CFG2: HGAIN off
w 0xab 0x0c          # CFG3: no sleep-after-interrupt
w 0xd6 0x7f          # AZ_CONFIG: autozero at first cycle
w 0xdd 0x00          # INTENAB: no interrupts
w 0x90 0x02          # CFG1: AGAIN 16x, AMUX = X on channel 3
w 0x81 0x23          # ATIME: (0x23+1) * 2.78 ms = 100 ms
w 0x80 0x01; sleep 0.01
w 0x80 0x03          # PON + AEN
sleep 0.3
echo "After:  ENABLE $(r 0x80) ATIME $(r 0x81) CFG1 $(r 0x90) CFG3 $(r 0xab) STATUS $(r 0x93)"
echo
printf '%6s %7s %7s %7s %7s\n' sec X Y Z IR1
for s in $(seq 1 "$SECS"); do
    printf '%6s %7s %7s %7s %7s\n' "$s" "$(word 0x9a)" "$(word 0x96)" "$(word 0x94)" "$(word 0x98)"
    sleep 1
done
w 0x80 0x00
echo "Sensor switched off. Reboot (or rebind apds9960) to return to the old state."
