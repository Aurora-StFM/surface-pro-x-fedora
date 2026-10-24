#!/usr/bin/env bash
# Collect the audio hardware state of the Surface Pro X during playback:
# codec (WCD9340) and speaker amplifier (WSA881x) registers read live from
# the hardware, SoundWire master and slave registers, mixer settings and the
# kernel log. For debugging the low speaker level.
#
# Run ON THE SURFACE as your normal user (uses sudo), volume at about 30%:
#   ./audio-dump.sh
# Result: ~/audio-dump-<time>.tar.gz
set -uo pipefail

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not with sudo" >&2; exit 1; }
OUT="$HOME/audio-dump-$(date +%H%M%S)"
mkdir -p "$OUT"
sudo -v || exit 1

DBG=/sys/kernel/debug
sudo mountpoint -q "$DBG" || sudo mount -t debugfs none "$DBG"

echo "==> Starting the audio DSP (if needed)"
for r in /sys/class/remoteproc/*; do
    if [ "$(cat "$r/name")" = adsp ] && [ "$(cat "$r/state")" != running ]; then
        echo start | sudo tee "$r/state" >/dev/null
        sleep 10
    fi
done

dump_regmaps() { # suffix
    # debugfs is root-only, so the directory listing needs sudo as well.
    local d name
    for d in $(sudo sh -c "ls -d $DBG/regmap/*"); do
        name="$(basename "$d")"
        case "$name" in
            *slim*|*sdw*|*wcd*|*wsa*|*soundwire*|*217*) ;;
            *) continue ;;
        esac
        # Read from the hardware, not the driver's cache.
        sudo sh -c "[ -e '$d/cache_bypass' ] && echo Y > '$d/cache_bypass'; cat '$d/name' '$d/registers' 2>&1; [ -e '$d/cache_bypass' ] && echo N > '$d/cache_bypass'" \
            > "$OUT/regmap-${name//[:\/]/_}-$1.txt" 2>&1
    done
    sudo find "$DBG/soundwire" -name 'qualcomm-registers' -exec sh -c 'cat "$1"' _ {} \; \
        > "$OUT/swr-master-$1.txt" 2>&1
}

echo "==> Registers while idle"
dump_regmaps idle

echo "==> Playing a 440 Hz tone and reading registers during playback"
sudo dmesg -C
speaker-test -c 2 -t sine -f 440 -l 3 > "$OUT/speaker-test.txt" 2>&1 &
ST=$!
sleep 3
dump_regmaps playing
amixer -c 0 contents > "$OUT/amixer.txt" 2>&1
wait "$ST"
sudo dmesg > "$OUT/dmesg-during-playback.txt"

uname -r > "$OUT/kernel.txt"
sudo ls -la "$DBG/regmap/" > "$OUT/regmap-list.txt" 2>&1
sudo find "$DBG/soundwire" > "$OUT/soundwire-tree.txt" 2>&1
cat /proc/asound/cards > "$OUT/cards.txt"

tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "==> Done: $OUT.tar.gz"
