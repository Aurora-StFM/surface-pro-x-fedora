#!/usr/bin/env bash
# Start the Surface Pro X audio DSP (ADSP) by hand, until it starts at boot.
#
# Run ON THE SURFACE as your normal user (it uses sudo), once per boot:
#   ./start-audio.sh
#
# It keeps the SLIMbus controller, the codec's SoundWire link and the speaker
# amplifiers out of runtime suspend (surface-pro-x-support 1.7+ does this with
# udev as well), starts the DSP, and waits until the speakers show up in
# PipeWire. Running it again when audio is already up just restarts PipeWire,
# which also recovers a speaker output that got stuck.
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

started=0
if [ "$(cat "$adsp/state")" = running ]; then
    echo "Audio DSP is already running."
else
    sudo -v || exit 1
    keep_on /sys/bus/platform/devices/*slim-ngd*
    echo "Starting the audio DSP..."
    echo start | sudo tee "$adsp/state" >/dev/null || { echo "error: start failed" >&2; exit 1; }
    started=1
fi

# Wait for the sound card (codec, SLIMbus and SoundWire come up after the DSP).
printf "Waiting for the sound card"
for _ in $(seq 1 30); do
    grep -q "Surface" /proc/asound/cards 2>/dev/null && break
    printf "."
    sleep 1
done
echo
if ! grep -q "Surface" /proc/asound/cards 2>/dev/null; then
    # After an ADSP restart (sleep, crash recovery) the card driver can give up
    # assembling the card too early and never retry. Rebind it once.
    echo "No sound card yet; asking the card driver to assemble it again..."
    drv=/sys/bus/platform/drivers/msm-snd-sdm845
    echo sound | sudo tee "$drv/unbind" >/dev/null 2>&1
    sleep 1
    echo sound | sudo tee "$drv/bind" >/dev/null 2>&1
    for _ in $(seq 1 15); do
        grep -q "Surface" /proc/asound/cards 2>/dev/null && break
        sleep 1
    done
fi
grep -q "Surface" /proc/asound/cards 2>/dev/null ||
    { echo "error: no sound card; check: sudo dmesg | grep -iE 'q6|apr|slim|wcd|wsa'" >&2; exit 1; }

# Give the speaker amplifiers a moment to attach, then keep the link up.
sleep 3
keep_on /sys/bus/platform/devices/wcd934x-soundwire* /sys/bus/soundwire/devices/sdw:*:0217:2110:*

# The first stream after the DSP starts fails on this firmware ("Memory_map_regions
# failed", ASoC -12). If PipeWire is the one that hits it, its speaker sink stays
# broken: links fail and every player hangs. Take that first failure with a short
# direct open of the hardware, then let PipeWire (re)open the card fresh.
# PipeWire is stopped meanwhile so it can't grab the card first.
units="pipewire.socket pipewire-pulse.socket pipewire wireplumber pipewire-pulse"
systemctl --user stop $units 2>/dev/null || :
if [ "$started" = 1 ]; then
    sleep 2
    for _ in 1 2; do
        timeout 5 aplay -q -D plughw:0,0 -f S16_LE -r 48000 -c 2 -d 1 /dev/zero >/dev/null 2>&1 || :
    done
fi
systemctl --user start $units 2>/dev/null || :
sleep 3

# Wait until PipeWire shows the speaker sink.
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
