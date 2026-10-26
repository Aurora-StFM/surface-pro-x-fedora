# Handover: Fedora KDE on the Surface Pro X

Context for continuing this project in a new chat. Attach this file and the
kit (or give the chat access to the GitHub repo) and say what to work on next.

## Setup

- **Device:** Microsoft Surface Pro X, SQ1 (SC8180X), Adreno 680. Fedora 44 KDE
  (Plasma 6.7.5) on its own NVMe, dual-boot with Windows. User `spx`,
  hostname `fedoraARM64`.
- **Build PC:** Fedora x86 laptop (Ubuntu distrobox available). The kit is
  cloned at `~/surface-pro-x-fedora`; see `docs/build-and-update.md`.
- **Repo:** github.com/Aurora-StFM/surface-pro-x-fedora. Commits as
  `Aurora-StFM <84717132+Aurora-StFM@users.noreply.github.com>`.
- **Kit:** `build.sh deps|kernel|support|firmware|image`. Kernel is
  linux-surface/kernel at commit `3d83d8ff8b3c` (6.18.3), patches in
  `kernel/patches/` applied with `git apply` by `kernel/build-kernel.sh`,
  extra config in `kernel/fedora.config`, package release in `config.env`
  (`KERNEL_PKG_RELEASE`). Device tree: `arch/arm64/boot/dts/qcom/sc8180x-surface-pro-x.dts`.
  Support package: `support/surface-pro-x-support.spec`, files in `support/files/`.
- **Working style:** the user runs commands on the Surface and pastes output.
  Give copy-paste blocks; scripts are delivered as files (remind `chmod +x`).
  Avoid `timeout` around commands that prompt for sudo (it locked the terminal).

## Versions

| Package | In the kit | Installed on the Surface |
|---|---|---|
| kernel-spx | 6.18.3-12 (patch 0010, TCS3430) | 6.18.3-11 |
| surface-pro-x-support | 1.13 | 1.11 package + manual copies of the 1.12/1.13 sleep and touch-resume services in `/etc/systemd/system/` (remove after installing 1.13: `sudo systemctl disable surface-pro-x-audio-sleep surface-pro-x-touch-resume` and delete the two files in /etc) |

## Kernel patches

0001 audio DT (WCD9340, WSA881x) · 0002/0003 SLIMbus width parameters ·
0004 SLPI sensor DSP · 0005 spi-hid wait for ready · 0006 lid switch DT ·
0007 pinctrl wakeirq dual-edge errata · 0008 WCD934x smart boost clock bit ·
0009 slim-ngd teardown deadlock on ADSP stop · 0010 TCS3430 light sensor
driver + DT compatible `ams,tcs3430`.

## Status

- **Works:** boot, display/GPU, WiFi, Bluetooth (support 1.7+), battery,
  keyboard/touchpad, touch + pen via iptsd (support package integration),
  lid switch, speakers (correct level), sleep with audio running (support
  1.12 service), touch after sleep (1.13), accelerometer rotation (SLPI +
  hexagonrpcd + libssc + iio-sensor-proxy in /usr/local via
  `tools/setup-sensors.sh`), Spotify in Firefox (Widevine), FEX for x86 apps.
- **Audio still started by hand** after boot: `~/start-audio.sh`
  (tools/start-audio.sh). The user wants to wait with autostart.
- **GTK4 apps:** turnip GMEM corruption; per-app `GSK_RENDERER=ngl` (e.g.
  Riff flatpak override). System-wide variant was removed (suspected of
  breaking playback). Vesktop glitches remain (only --disable-gpu-compositing
  helps, too slow).

## In progress

1. **Ambient light sensor.** i2c0 0x39 is an AMS TCS3430 (ID 0xdc), not an
   APDS9960. Confirmed working by hand (`tools/als-test.sh`). Patch 0010 adds
   a `tcs3430` IIO driver (in_illuminance_input from Y, autogain 1x-128x,
   200 ms, `lux_coef` module parameter default 20000). Compiled for arm64,
   not yet tested on the device. Next: user builds/installs -12, checks
   `in_illuminance_input` and `monitor-sensor`, enables KDE "Automatically
   adapt to environment" (under Display brightness), calibrates lux_coef
   against a phone lux meter.
2. **KDE tablet mode / auto-rotate.** The tablet-mode switch ("Microsoft
   Surface KIP Tablet Mode Switch", event19) and KWin's
   `org.kde.KWin.TabletModeManager.tabletMode` both follow the cover.
   `~/.config/kwinoutputconfig.json` has `"autoRotation": "InTabletMode"`
   for eDP-1. Yet the screen rotates in laptop position, the Display
   settings page has no auto-rotate option, Plasma's touch-mode spacing
   never appears, and the on-screen keyboard appears in both modes.
   Hypothesis: touching the screen flips KWin into tablet mode. Pending test:
   read `tabletMode` before/after a screen tap in laptop position; list
   `/usr/lib64/qt6/plugins/sensors/` and run `kcmshell6 kcm_kscreen` with
   `QT_LOGGING_RULES="qt.sensors*=true;kcm_kscreen*=true;kscreen*=true"`.

## Open items (user's priority)

1. Sensors (above), then proximity (ADUX1080 behind the SLPI) and compass
   together with the accelerometer (with both enabled the accelerometer stops).
2. Spotify x86 under FEX (shows "Page Unresponsive"; try --no-sandbox
   --no-zygote, launcher + menu entry; `~/spotify-x86`).
3. Later: audio autostart, microphones, phantom headphone jack (MBHC),
   "Memory_map_regions failed" on the first stream after ADSP start,
   occasional SLPI `sensor_process` crash, Vesktop glitches, report the
   turnip GMEM bug to Mesa, cameras, LTE.
4. Pause/play spam to media players when PipeWire starts (evtest on the
   jack device showed nothing; low priority).

## Key findings to remember

Details are in `docs/hardware-findings.md`. In short:

- Speaker level: WCD934x boost clock bit (0008) and PipeWire using S24 on a
  16-bit SLIMbus path (WirePlumber rule forces S16LE).
- Silent playback: phantom headphone jack in UCM, and Fedora's muted
  "Multimedia" role sink.
- Sleep: systemd-sleep freezes user.slice before running system-sleep
  hooks, so audio teardown must run in a service before sleep.target. The
  ADSP restart needs an msm-snd-sdm845 unbind/bind to reassemble the card.
- Touch: spi-hid powers down on last close; iptsd holder service waits for
  `ready`; LIBINPUT_IGNORE_DEVICE on the native single-touch devices.
