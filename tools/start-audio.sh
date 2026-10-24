#!/usr/bin/env bash
# Start the Surface Pro X audio DSP (ADSP) by hand, until it starts at boot.
#
# Run ON THE SURFACE as your normal user (it uses sudo), once per boot:
#   ./start-audio.sh
#
# It keeps the SLIMbus controller, the codec's SoundWire link and the speaker
# amplifiers out of runtime suspend (surface-pro-x-support 1.7+ does this with
# udev as well), starts the DSP, and waits until the speakers show up in
# PipeWire. Running it again when audio is already up does nothing.
set -uo pipefail

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not with sudo" >&2; exit 1; }

keep_on() { # path glob...
    local d
    for d in "$@"; do
        [ -e "$d/power/control" ] && echo on | sudo tee "$d/power/control" >/dev/null
    done
}

adsp=""
for r in /sys/class/remoteproc/*; do
    [ "$(cat "$r/name" 2>/dev/null)" = adsp ] && adsp="$r"
done
[ -n "$adsp" ] || { echo "error: no audio DSP (adsp) remoteproc found" >&2; exit 1; }

if [ "$(cat "$adsp/state")" = running ]; then
    echo "Audio DSP is already running."
else
    sudo -v || exit 1
    keep_on /sys/bus/platform/devices/*slim-ngd*
    echo "Starting the audio DSP..."
    echo start | sudo tee "$adsp/state" >/dev/null || { echo "error: start failed" >&2; exit 1; }
fi

# Wait for the sound card (codec, SLIMbus and SoundWire come up after the DSP).
printf "Waiting for the sound card"
for _ in $(seq 1 30); do
    grep -q "Surface" /proc/asound/cards 2>/dev/null && break
    printf "."
    sleep 1
done
echo
grep -q "Surface" /proc/asound/cards 2>/dev/null ||
    { echo "error: no sound card after 30 s; check: sudo dmesg | grep -iE 'q6|apr|slim|wcd|wsa'" >&2; exit 1; }

# Give the speaker amplifiers a moment to attach, then keep the link up.
sleep 3
keep_on /sys/bus/platform/devices/wcd934x-soundwire* /sys/bus/soundwire/devices/sdw:*:0217:2110:*

# PipeWire notices the new card by itself; wait until the speaker sink exists.
for _ in $(seq 1 10); do
    wpctl status 2>/dev/null | grep -q "Speaker playback" && break
    sleep 1
done
if wpctl status 2>/dev/null | grep -q "Speaker playback"; then
    echo "Audio is ready (speakers: $(wpctl status | grep -m1 'Speaker playback' | sed 's/^[^0-9]*//'))."
else
    echo "The sound card is up, but PipeWire hasn't shown the speakers yet."
    echo "Try: systemctl --user restart wireplumber"
fi
