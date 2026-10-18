Name:           surface-pro-x-support
Version:        1.7
Release:        1
Summary:        Fedora integration for the Microsoft Surface Pro X
License:        MIT
BuildArch:      noarch
Source1:        95-surface-pro-x.install
Source2:        90-surface-pro-x.conf.dracut
Source3:        rmtfs-surface-pro-x.conf
Source4:        rmtfs-prepare
Source5:        65-surface-pro-x-rmtfs.rules
Source6:        50-surface-pro-x.preset
Source7:        surface-pro-x-install
Source8:        surface-pro-x-diag
Source9:        SurfaceProX.conf
Source10:       HiFi.conf
Source11:       66-surface-pro-x-audio.rules

Requires:       systemd-udev
Requires:       dracut
Requires:       rmtfs
Requires:       tqftpserv
Requires:       btrfs-progs
Requires:       efibootmgr
Requires:       util-linux
Requires:       dosfstools
Requires:       e2fsprogs
Requires:       alsa-ucm

%description
Glue that makes Fedora boot and run on the Surface Pro X with kernel-spx:
- kernel-install plugin that adds the Surface Pro X device tree and the
  required kernel arguments (efi=novamap clk_ignore_unused) to boot entries
- dracut settings for a generic initramfs (USB and NVMe boot)
- rmtfs override that serves dummy EFS files to the modem (needed for WiFi)
- presets enabling rmtfs and tqftpserv
- surface-pro-x-install, which copies a USB-booted system next to Windows
- surface-pro-x-diag, which collects hardware diagnostics for bring-up work
- ALSA UCM profile for the speakers and headset jack (experimental)

%prep

%build

%install
install -Dm0755 %{SOURCE1} %{buildroot}/usr/lib/kernel/install.d/95-surface-pro-x.install
install -Dm0644 %{SOURCE2} %{buildroot}/usr/lib/dracut/dracut.conf.d/90-surface-pro-x.conf
install -Dm0644 %{SOURCE3} %{buildroot}/usr/lib/systemd/system/rmtfs.service.d/90-surface-pro-x.conf
install -Dm0755 %{SOURCE4} %{buildroot}/usr/libexec/surface-pro-x/rmtfs-prepare
install -Dm0644 %{SOURCE5} %{buildroot}/usr/lib/udev/rules.d/65-surface-pro-x-rmtfs.rules
install -Dm0644 %{SOURCE11} %{buildroot}/usr/lib/udev/rules.d/66-surface-pro-x-audio.rules
install -Dm0644 %{SOURCE6} %{buildroot}/usr/lib/systemd/system-preset/50-surface-pro-x.preset
install -Dm0755 %{SOURCE7} %{buildroot}/usr/sbin/surface-pro-x-install
install -Dm0755 %{SOURCE8} %{buildroot}/usr/sbin/surface-pro-x-diag
mkdir -p %{buildroot}/var/lib/rmtfs
install -Dm0644 %{SOURCE9} %{buildroot}/usr/share/alsa/ucm2/Microsoft/SurfaceProX/SurfaceProX.conf
install -Dm0644 %{SOURCE10} %{buildroot}/usr/share/alsa/ucm2/Microsoft/SurfaceProX/HiFi.conf
# The card's driver is "sdm845"; UCM falls back to conf.d/<driver>/<driver>.conf.
mkdir -p %{buildroot}/usr/share/alsa/ucm2/conf.d/sdm845
ln -s ../../Microsoft/SurfaceProX/SurfaceProX.conf %{buildroot}/usr/share/alsa/ucm2/conf.d/sdm845/sdm845.conf

%post
# Rebuild initramfs images so the dracut change applies to installed kernels.
for k in /usr/lib/modules/*.spx.*; do
    [ -d "$k" ] && dracut -f --kver "$(basename "$k")" >/dev/null 2>&1 || :
done
if [ $1 -eq 1 ]; then
    systemctl --no-reload preset rmtfs.service tqftpserv.service >/dev/null 2>&1 || :
fi
/usr/libexec/surface-pro-x/rmtfs-prepare >/dev/null 2>&1 || :

%files
/usr/lib/kernel/install.d/95-surface-pro-x.install
/usr/lib/dracut/dracut.conf.d/90-surface-pro-x.conf
%dir /usr/lib/systemd/system/rmtfs.service.d
/usr/lib/systemd/system/rmtfs.service.d/90-surface-pro-x.conf
%dir /usr/libexec/surface-pro-x
/usr/libexec/surface-pro-x/rmtfs-prepare
/usr/lib/udev/rules.d/65-surface-pro-x-rmtfs.rules
/usr/lib/udev/rules.d/66-surface-pro-x-audio.rules
/usr/lib/systemd/system-preset/50-surface-pro-x.preset
/usr/sbin/surface-pro-x-install
/usr/sbin/surface-pro-x-diag
%dir /var/lib/rmtfs
%dir /usr/share/alsa/ucm2/Microsoft
%dir /usr/share/alsa/ucm2/Microsoft/SurfaceProX
/usr/share/alsa/ucm2/Microsoft/SurfaceProX/SurfaceProX.conf
/usr/share/alsa/ucm2/Microsoft/SurfaceProX/HiFi.conf
/usr/share/alsa/ucm2/conf.d/sdm845/sdm845.conf

%changelog
* Sun Oct 18 2026 Surface Pro X Fedora kit <spx@localhost> - 1.7-1
- udev: keep the SLIMbus controller, the codec's SoundWire link and the
  WSA881x speaker amplifiers out of runtime suspend (they drop off the bus
  between streams otherwise)

* Sat Oct 17 2026 Surface Pro X Fedora kit <spx@localhost> - 1.6-1
- dracut: revert the 1.5 change; starting the ADSP locks up the machine, so
  it must not start automatically at boot yet

* Sat Oct 17 2026 Surface Pro X Fedora kit <spx@localhost> - 1.5-1
- dracut: omit qcom_q6v5_pas from the initramfs so the ADSP/CDSP start after
  the root filesystem (with their firmware) is mounted

* Sat Oct 17 2026 Surface Pro X Fedora kit <spx@localhost> - 1.4-1
- kernel-install plugin: drop blank lines from BLS entries; Fedora GRUB stops
  parsing at the first one, which hid the devicetree line

* Sat Oct 17 2026 Surface Pro X Fedora kit <spx@localhost> - 1.3-1
- kernel-install plugin: also run for the "bls" layout Fedora reports on
  GRUB systems; it was skipping, so boot entries had no devicetree line

* Fri Oct 16 2026 Surface Pro X Fedora kit <spx@localhost> - 1.2-1
- Add experimental ALSA UCM profile

* Fri Oct 16 2026 Surface Pro X Fedora kit <spx@localhost> - 1.1-1
- Add surface-pro-x-diag

* Thu Oct 15 2026 Surface Pro X Fedora kit <spx@localhost> - 1.0-1
- Initial package
