# Building on Windows with WSL

Use this instead of [Step 1 in the README](../README.md#step-1-build-the-image-on-a-fedora-pc) if your build PC runs Windows. The kit runs inside Fedora on WSL2. Once the image is on a USB drive, continue with [Step 2](../README.md#step-2-prepare-windows-on-the-surface).

You need about 50 GB free disk space and a 16 GB or larger USB drive. A fast PC builds the kernel in about 20–30 minutes. The image step runs ARM programs under emulation and takes another 20–40 minutes.

## 1. Install Fedora for WSL

In PowerShell, list the available versions and install the newest Fedora:

```powershell
wsl --list --online
wsl --install FedoraLinux-44
```

## 2. Check that systemd is running

Open the Fedora shell. systemd is needed to register qemu for ARM emulation:

```bash
systemctl is-system-running   # anything except "offline" is fine
```

If it reports `offline`, add the lines below to `/etc/wsl.conf`, then run `wsl --shutdown` in PowerShell and reopen Fedora:

```ini
[boot]
systemd=true
```

## 3. Get the kit and build

Put the kit in your Linux home folder. Don't use `/mnt/c/...`: Windows drives are slow from WSL and don't support the Linux permissions, symlinks and loop devices the build needs. The build stops with an error if its output folder is on a Windows drive.

```bash
sudo dnf install -y git
git clone https://github.com/Aurora-StFM/surface-pro-x-fedora.git ~/surface-pro-x-fedora
cd ~/surface-pro-x-fedora
./build.sh deps          # installs cross-compiler, rpm-build, qemu, ...
sudo ./build.sh all      # kernel, firmware, support RPMs, then the image
```

If you downloaded the kit as an archive in Windows instead, copy it into your home folder first, for example:

```bash
rsync -a --exclude out /mnt/c/Users/<you>/Downloads/surface-pro-x-fedora/ ~/surface-pro-x-fedora/
```

The results go in `out/`:

- **`out/rpms/`:** `kernel-spx`, `surface-pro-x-firmware` and `surface-pro-x-support`
- **`out/Fedora-KDE-SurfaceProX-44.raw`:** the bootable disk image

Fedora 45 releases on 20 October 2026. To build on it instead, run `FEDORA_RELEASE=45 sudo -E ./build.sh image` once it's out.

If the image step says DNS doesn't work inside the image, check that `getent hosts mirrors.fedoraproject.org` works in the WSL shell itself.

## 4. Write the image to a USB drive from Windows

Open `\\wsl$\FedoraLinux-44\home\<you>\surface-pro-x-fedora\out\` in Explorer. Then use either tool:

- [Fedora Media Writer](https://fedoraproject.org/workstation/download): choose "Select .iso file" and pick the `.raw` file.
- [Rufus](https://rufus.ie): rename the file to `.img` and write it in DD mode.

**Optional: firmware from your own Surface.** To use files pulled from your SQ1's own Windows instead of the linux-surface copies, run [`scripts/getfw.py`](https://github.com/linux-surface/aarch64-firmware) against your Windows partition or a Surface recovery image. Then build with `./build.sh firmware --from-dir <output>` and run `sudo ./build.sh image` again.

## Rebuilding later

The cheat sheet in [`build-and-update.md`](build-and-update.md) works the same in WSL. To copy the new RPMs to the Surface, either use `scp` from the WSL shell or open the `out\rpms\` folder through `\\wsl$\` in Explorer and copy them to a USB stick.

Next: [Step 2: Prepare Windows on the Surface](../README.md#step-2-prepare-windows-on-the-surface).
