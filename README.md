# Fedora KDE for the Surface Pro X

An unofficial kit that builds Fedora KDE Plasma for the Microsoft Surface Pro X (SQ1/SQ2) and installs it next to Windows.

> **About this project.** This kit was written with an AI assistant (Claude) and tested by one person on one Surface Pro X SQ1. It is **experimental**. It is **not affiliated with or endorsed by** the [linux-surface](https://github.com/linux-surface) project, whose kernel and firmware work it packages. Please don't report problems with this kit to linux-surface. Open an issue here instead. Read the scripts before running them as root.

It reuses the work of the [linux-surface Surface Pro X project](https://github.com/linux-surface/surface-pro-x):

- **Kernel:** the linux-surface `spx/v6.18.3` kernel with the Surface Pro X device tree.
- **Firmware:** the linux-surface firmware set (modem/WiFi DSP, GPU, Bluetooth).
- **Kernel arguments:** the ones from the project wiki.

The kit packages all of this the Fedora way, as signed RPMs plus a few integration files. The base system is the official Fedora KDE aarch64 disk image.

> **About the SQ1.** The device tree is labelled "SQ2", but the SQ1 and SQ2 use the same Qualcomm SC8180X platform. The kit has been tested on an SQ1, booting from the internal NVMe next to Windows 11 Home.

## Status (tested on an SQ1, October 2026)

| Area | Status |
|---|---|
| Boot from USB and internal NVMe, GRUB with the device tree | Works |
| Display and GPU acceleration, battery status, Type Cover keyboard and touchpad | Works |
| WiFi | Works |
| Touchscreen | Single-touch works; multitouch and pen need [iptsd](https://github.com/linux-surface/iptsd) |
| Bluetooth | The firmware loads, but it does not work yet (under investigation) |
| Audio | **Partly working, experimental.** See [Audio](#audio-experimental) |
| Cameras, LTE, sensors | Not working yet. See `docs/hardware-findings.md` |
| Known issue | The screen sometimes stays black after boot (display handover). Hold the power button to restart. |

## What's in the kit

| Path | Purpose |
|---|---|
| `build.sh` | Entry point: `deps`, `kernel`, `firmware`, `support`, `image`, `all` |
| `config.env` | Pinned versions (kernel commit, configs, firmware, Fedora release) |
| `kernel/` | Cross-compiles the kernel and packages it as `kernel-spx` (aarch64 RPM). `fedora.config` adds SELinux and other settings Fedora needs. Patches in `kernel/patches/` are applied before building. |
| `firmware/` | Packages the firmware as `surface-pro-x-firmware` |
| `support/` | `surface-pro-x-support`: boot-entry plugin, initramfs settings, rmtfs fix, service presets, the `surface-pro-x-install` dual-boot installer and the `surface-pro-x-diag` diagnostics tool |
| `docs/hardware-findings.md` | What the Windows export showed about audio, cameras and sensors, and the plan for each |
| `windows/` | `Collect-SurfaceProXInfo.ps1`: exports device, ACPI and driver information from Windows on the Surface |
| `image/build-image.sh` | Downloads and verifies the Fedora KDE image, installs the packages into it, and removes the stock kernel |

The built packages do the following:

- **`kernel-spx`** installs like a Fedora kernel. dnf keeps several versions, and `kernel-install` builds the initramfs and boot entry.
- **The boot-entry plugin** (`95-surface-pro-x.install`) copies the device tree to `/boot/dtb-<version>/`. It adds a `devicetree` line and `efi=novamap clk_ignore_unused` to that kernel's boot entry. Fedora's GRUB reads the `devicetree` key directly.
- **The firmware package** puts Surface-only files in `/usr/lib/firmware/qcom/msft/surface/pro-x-sq2/`. It puts its patched WiFi, Bluetooth and GPU files in `/usr/lib/firmware/updates/`, which the kernel checks first. That way nothing conflicts with Fedora's `linux-firmware` packages.
- **The rmtfs fix:** the modem's storage partitions can't be read from Linux yet, so `rmtfs` serves zero-filled dummy files instead. This is the same workaround as linux-surface's `rmtfs-dummy` package, and WiFi needs it. `pd-mapper` isn't needed; the kernel's built-in version supports this chip.
- **Kernel updates:** Fedora's stock kernel is removed from the image and excluded in `/etc/dnf/dnf.conf`. It has no Surface Pro X device tree, so it can't boot this device. You update the kernel by rebuilding `kernel-spx`.
- **Signing:** every RPM is signed with a local key that the kit creates in `out/signing/`. Fedora 45 rejects unsigned packages by default.

---

## Step 1: Build the image on your Windows PC (WSL)

You need about 50 GB free disk space and a 16 GB or larger USB drive. A fast PC builds the kernel in about 20–30 minutes. The image step runs ARM programs under emulation and takes another 20–40 minutes.

1. In PowerShell, install Fedora for WSL. List the available versions first and pick the newest Fedora:

   ```powershell
   wsl --list --online
   wsl --install FedoraLinux-44
   ```

2. Open the Fedora shell. Check that systemd is running; it's needed for ARM emulation:

   ```bash
   systemctl is-system-running   # anything except "offline" is fine
   ```

   If it reports `offline`, add the lines below to `/etc/wsl.conf`, then run `wsl --shutdown` in PowerShell and reopen Fedora:

   ```ini
   [boot]
   systemd=true
   ```

3. Copy this kit into your Linux home folder. Don't use `/mnt/c/...`, which is slow and breaks file permissions. Then build:

   ```bash
   cd ~/surface-pro-x-fedora
   ./build.sh deps          # installs cross-compiler, rpm-build, qemu, ...
   sudo ./build.sh all      # kernel, firmware, support RPMs, then the image
   ```

   The results go in `out/`:

   - **`out/rpms/`:** `kernel-spx`, `surface-pro-x-firmware` and `surface-pro-x-support`
   - **`out/Fedora-KDE-SurfaceProX-44.raw`:** the bootable disk image

   Fedora 45 releases on 20 October 2026. To build on it instead, run `FEDORA_RELEASE=45 sudo -E ./build.sh image` once it's out.

4. Write the image to the USB drive from Windows. Open `\\wsl$\FedoraLinux-44\home\<you>\surface-pro-x-fedora\out\` in Explorer. Then use either tool:

   - [Fedora Media Writer](https://fedoraproject.org/workstation/download): choose "Select .iso file" and pick the `.raw` file.
   - [Rufus](https://rufus.ie): rename the file to `.img` and write it in DD mode.

   **Optional: firmware from your own Surface.** To use files pulled from your SQ1's own Windows instead of the linux-surface copies, run [`scripts/getfw.py`](https://github.com/linux-surface/aarch64-firmware) against your Windows partition or a Surface recovery image. Then build with `./build.sh firmware --from-dir <output>` and run `sudo ./build.sh image` again.

## Step 2: Prepare Windows on the Surface

1. **Back up**, and save your **BitLocker recovery key** (from Settings › Privacy & security › Device encryption, or https://aka.ms/myrecoverykey). Turning off Secure Boot makes BitLocker ask for the key on the next Windows start. You can avoid that by suspending BitLocker first:

   ```powershell
   manage-bde -protectors -disable C: -RebootCount 3
   ```

   On Windows Home that command fails with error `0x8031005a`. Home only has Device encryption, so check its switch instead. If Settings › Privacy & security › Device encryption shows **Off**, the drive isn't encrypted and there's nothing to suspend. To double-check, `manage-bde -status C:` should show `Conversion Status: Fully Decrypted`.

2. **Make room:** open Disk Management (`diskmgmt.msc`), right-click C:, choose **Shrink Volume**, and free at least 40 GB. Leave it as *Unallocated*; don't create a partition there.

3. **Turn off Secure Boot:** shut down. Hold **Volume Up**, press and release **Power**, and keep holding Volume Up until the Surface UEFI screen appears. Go to **Security › Secure Boot** and choose **Disabled** (on older firmware: **Change configuration › None**). Then exit.

## Step 3: Boot Fedora from USB

1. Plug in the USB drive. A USB-C stick or an adapter both work.
2. Shut down. Hold **Volume Down**, press and release **Power**, and keep holding until the Surface logo shows. It boots from USB.
3. In GRUB, pick **Fedora Linux (6.18.3-1.spx.aarch64)**.
   - Loading and unpacking the initramfs can take a minute, so wait.
   - A black screen for more than about 20 seconds is the known display issue. Hold Power to restart and try again.
4. On the first boot, SELinux relabels the files and the system reboots once. Then the KDE setup creates your user.
5. Check that the hardware works before installing to the SSD:

   ```bash
   systemctl status rmtfs tqftpserv           # both should be active
   sudo dmesg | grep -iE 'remoteproc|ath10k'  # modem DSP up, ath10k registered
   nmcli device wifi list                     # should list networks
   ```

## Step 4: Install next to Windows

From the USB system:

```bash
sudo surface-pro-x-install          # add --disk /dev/nvme0n1 if it picks the wrong disk
```

The installer does the following:

- Shows the free space it found and the partitions it will create (600 MiB EFI, 1 GiB `/boot`, and the rest as btrfs root), then asks you to type `YES`.
- Creates those partitions **only in the unallocated space**. Windows and its EFI partition are never modified.
- Copies the running system with btrfs send/receive and updates every UUID reference.
- Adds a **Windows Boot Manager** item to the GRUB menu and creates a UEFI entry named **Fedora (Surface Pro X)**.

When it finishes, remove the USB drive and reboot. GRUB lets you choose Fedora or Windows. You can also hold Volume Down at power-on and pick from the Surface boot menu.

If `efibootmgr` fails, the script prints the `bcfg` command to add the entry from a UEFI shell, as described on the [linux-surface wiki](https://github.com/linux-surface/surface-pro-x/wiki/Basic-Setup#manual-uefi-boot-entry).

## Diagnostics (for getting more hardware working)

**On Fedora (on the Surface):**

```bash
sudo surface-pro-x-diag
```

It prints a short health summary and saves `surface-pro-x-diag-<date>.tar.gz` in your home folder. Inside are the kernel logs, the state of the modem and other chips, devices without a driver, firmware-loading results, and the USB, PCI, input, audio, power and CPU details. Nothing on the system is changed. MAC addresses, serial numbers, IP addresses and WiFi network names are masked; pass `--no-sanitize` to keep them.

The script is also in `support/files/`. You can copy it to a Surface that runs an older build and run it with `sudo bash surface-pro-x-diag`.

**On Windows (on the Surface):** in an administrator PowerShell, from the kit's `windows` folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Collect-SurfaceProXInfo.ps1
```

It saves `SurfaceProX-windows-info-<date>.zip` on the Desktop with:

- every device with its hardware IDs and ACPI path
- the ACPI tables
- the driver `.inf` files
- the Qualcomm audio, camera, sensor and DSP driver configuration

To also get the SSDT tables, put `acpidump.exe` from Intel's ACPICA Windows tools next to the script. Use `-SkipDriverFiles` for a small zip. The driver files belong to Microsoft and Qualcomm, so share the zip for debugging but don't post it publicly.

## Audio (experimental)

The patches in `kernel/patches/` add the audio hardware to the device tree, following the Lenovo Yoga C630, which has the same audio design:

- WCD9340 codec on SLIMbus
- two WSA881x speaker amplifiers
- APR/q6 on the ADSP

The SMMU stream IDs come from the Surface's own Windows IORT table. `docs/hardware-findings.md` records where every value comes from and every test result.

**What works:** the ADSP starts, SLIMbus comes up, the codec and both speaker amplifiers are detected, and playback reaches both speakers.

**What does not work yet:**

- **The speaker level is far too low.** You need the volume at 100% with your ear next to the speaker. The amplifier gain, compander, boost and sample-format tests have ruled out the obvious causes; the findings document lists them.
- **The ADSP does not start automatically yet.** Start it by hand after boot:

```bash
echo on | sudo tee /sys/bus/platform/devices/qcom,slim-ngd*/power/control
echo start | sudo tee /sys/class/remoteproc/remoteproc2/state
sleep 10
echo on | sudo tee /sys/bus/platform/devices/wcd934x-soundwire*/power/control
for d in /sys/bus/soundwire/devices/sdw:*:0217:2110:*; do echo on | sudo tee $d/power/control; done
```

The `power/control` lines keep the SLIMbus controller, the SoundWire link and the speaker amplifiers out of runtime suspend. Without them, the amplifiers drop off the bus between streams. With `surface-pro-x-support` 1.7 or later installed, udev does this automatically, so only the `echo start` line is needed.

**Without speaker protection.** Windows protects the speakers with feedback-based speaker protection, and Linux doesn't have it here. Keep the volume moderate once the level problem is solved.

Kernel parameters for testing:

| Parameter | Effect |
|---|---|
| `snd_soc_sdm845.be_bits` | SLIMbus backend width, 16 (default) or 24 |
| `q6afe_dai.spx_slim_bits` | Forces the ADSP SLIMbus port width; 0 = auto |
| `snd_soc_wcd934x.spx_rx_bps` | Forces the codec's SLIMbus RX channel width; 0 = auto |

Only 16/16 works on this hardware. Every other combination stalls playback.

`kernel/debug-patches/` holds the step-by-step SLIMbus/BAM logging used during bring-up. It is not applied by default; copy a patch into `kernel/patches/` to use it.

## Updates

- **Fedora packages:** `sudo dnf upgrade` works normally. Fedora's own kernel is excluded.
- **Fedora 45 and later:** `dnf system-upgrade` keeps `kernel-spx`.
- **New Surface kernel:** when linux-surface tags a new `spx/vX.Y.Z`, update `KERNEL_COMMIT` and `KERNEL_VERSION` in `config.env`. Then run `./build.sh kernel`, copy the new `kernel-spx-*.rpm` to the Surface, and run `sudo dnf install ./kernel-spx-*.rpm`. The signing key is already trusted there. The previous kernel stays in the GRUB menu as a fallback.
  - You may also need newer `BASE_CONFIG_URL` and `SPX_CONFIG_URL` pins. Copy them from the `PKGBUILD` in [linux-surface/aarch64-packages](https://github.com/linux-surface/aarch64-packages/tree/main/linux-surface).

## Troubleshooting

| Symptom | What to try |
|---|---|
| Stops right after the GRUB menu | In GRUB, press `e` and check the entry has `devicetree /dtb-…/qcom/sc8180x-surface-pro-x.dtb` and `efi=novamap clk_ignore_unused`. Fedora 44's GRUB starts the kernel through the firmware (`LoadImage`), so the [executable-memory problem](https://github.com/linux-surface/grub-image-aarch64) that older GRUB builds had on this device shouldn't happen. If it still hangs at "Loading kernel", boot with the [linux-surface GRUB image](https://github.com/linux-surface/grub-image-aarch64) and report back. |
| Black screen after boot messages | Known display handover issue. Restart and retry. If it happens every time, add `module_blacklist=msm` to the kernel arguments to stay on the basic framebuffer while debugging. |
| No WiFi | `journalctl -b -u rmtfs -u tqftpserv` and `sudo dmesg \| grep -iE 'q6v5\|mpss\|ath10k'`. Check that `/usr/lib/firmware/qcom/msft/surface/pro-x-sq2/` exists. |
| No Bluetooth | `sudo dmesg \| grep -i qca`, `bluetoothctl show`, `sudo btmgmt info`. The firmware package provides the `crnv01`/`crbtfw01` links the [wiki](https://github.com/linux-surface/surface-pro-x/wiki/Bluetooth) describes. |
| Only single-touch, no pen | Install [iptsd](https://github.com/linux-surface/iptsd) (build from source with meson). |
| UEFI entry missing after a firmware update | Pick the drive from the Volume Down boot menu, then run `sudo efibootmgr --create --disk /dev/nvme0n1 --part <ESP#> --label "Fedora (Surface Pro X)" --loader '\EFI\fedora\shimaa64.efi'`. |

**Removing Fedora:**

1. In Windows Disk Management, delete the three "Fedora" partitions.
2. In an admin PowerShell, delete the leftover boot entry: run `bcdedit /enum firmware` to find its identifier, then `bcdedit /delete {id}`.
3. Turn Secure Boot back on in the Surface UEFI.

## Building pieces separately

```bash
./build.sh kernel                      # out/rpms/kernel-spx-*.aarch64.rpm
./build.sh firmware [--from-dir DIR]   # out/rpms/surface-pro-x-firmware-*.noarch.rpm
./build.sh support                     # out/rpms/surface-pro-x-support-*.noarch.rpm
sudo ./build.sh image [--image Fedora-KDE-Desktop-Disk-44-….aarch64.raw.xz]
```

Environment overrides: `JOBS` (parallel compile jobs), `FEDORA_RELEASE`, `OUT_DIR`, `IMAGE_EXTRA_GB`, and any variable in `config.env`.

## License

The scripts, spec files and integration files are MIT licensed (see `LICENSE`). The kernel patches in `kernel/patches/` and `kernel/debug-patches/` change the Linux kernel and are GPL-2.0, like the kernel. No firmware files are included in this repository. `./build.sh firmware` downloads them from the linux-surface firmware repository, or takes them from your own Windows install with `--from-dir`, when you build. The firmware belongs to Microsoft and Qualcomm.

## Credits

This kit mainly packages other people's work: Maximilian Luz (qzed) and the [linux-surface](https://github.com/linux-surface) contributors for the Surface Pro X kernel, device tree, firmware tooling and documentation, and the [linux-msm](https://github.com/linux-msm) project for rmtfs and tqftpserv. The firmware files belong to Microsoft and Qualcomm; build the firmware package only for a device you own.
