# Binary-only package: the kernel is cross-compiled by build-kernel.sh and the
# staged tree is passed in as Source0. Pass kver, kversion, krelease and
# kcommit with --define.

%global debug_package %{nil}
%global __os_install_post %{nil}
%global __strip /bin/true
%global _build_id_links none

Name:           kernel-spx
Version:        %{kversion}
Release:        %{krelease}
Summary:        Linux kernel for the Microsoft Surface Pro X (linux-surface spx branch)
License:        GPL-2.0-only
URL:            https://github.com/linux-surface/kernel
Source0:        kernel-spx-stage.tar
ExclusiveArch:  aarch64
AutoReqProv:    no

Requires:       coreutils
Requires:       kmod
Requires:       dracut
Requires(posttrans): systemd-udev
Requires(preun): systemd-udev
Recommends:     surface-pro-x-support
Recommends:     surface-pro-x-firmware

# Let dnf keep several versions installed side by side, like Fedora's kernel.
Provides:       installonlypkg(kernel)
Provides:       kernel-uname-r = %{kver}
Provides:       kernel-core-uname-r = %{kver}
Provides:       kernel-modules-uname-r = %{kver}
Provides:       kernel-modules-core-uname-r = %{kver}

%description
Linux %{kversion} from the linux-surface "spx" branch (commit %{kcommit}),
with the Surface Pro X device tree, built with a Fedora-compatible
configuration (SELinux, btrfs). Kernel %{kver}.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}

%install
cp -a . %{buildroot}/

# File list for everything that was staged.
(cd %{buildroot} && find usr/lib/modules/%{kver} -mindepth 1 -maxdepth 1 | sed 's|^|/|') > %{_builddir}/kernel-files.list

# Files created later by depmod and kernel-install.
for f in alias alias.bin builtin.alias.bin builtin.bin dep dep.bin devname \
         softdep symbols symbols.bin weakdep; do
    touch %{buildroot}/usr/lib/modules/%{kver}/modules.$f
done
mkdir -p %{buildroot}/boot/dtb-%{kver}
for f in vmlinuz-%{kver} System.map-%{kver} config-%{kver} initramfs-%{kver}.img; do
    touch %{buildroot}/boot/$f
done

%posttrans
/usr/bin/kernel-install add %{kver} /usr/lib/modules/%{kver}/vmlinuz || exit $?

%preun
/usr/bin/kernel-install remove %{kver} || :

%files -f %{_builddir}/kernel-files.list
%dir /usr/lib/modules/%{kver}
%ghost /usr/lib/modules/%{kver}/modules.alias
%ghost /usr/lib/modules/%{kver}/modules.alias.bin
%ghost /usr/lib/modules/%{kver}/modules.builtin.alias.bin
%ghost /usr/lib/modules/%{kver}/modules.builtin.bin
%ghost /usr/lib/modules/%{kver}/modules.dep
%ghost /usr/lib/modules/%{kver}/modules.dep.bin
%ghost /usr/lib/modules/%{kver}/modules.devname
%ghost /usr/lib/modules/%{kver}/modules.softdep
%ghost /usr/lib/modules/%{kver}/modules.symbols
%ghost /usr/lib/modules/%{kver}/modules.symbols.bin
%ghost /usr/lib/modules/%{kver}/modules.weakdep
%ghost %attr(0755, root, root) /boot/vmlinuz-%{kver}
%ghost %attr(0644, root, root) /boot/System.map-%{kver}
%ghost %attr(0644, root, root) /boot/config-%{kver}
%ghost %attr(0600, root, root) /boot/initramfs-%{kver}.img
%ghost %dir /boot/dtb-%{kver}

%changelog
* Sun Oct 25 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- slim-ngd: only refuse transfers while the devices are being torn down,
  not whenever the state is DOWN; the -10 change also blocked the capability
  exchange at ADSP start, so audio didn't come up

* Sun Oct 25 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- slim-ngd: don't hold tx_lock while reporting devices absent on ADSP
  shutdown/SSR; the codec teardown writes over SLIMbus and took the same
  lock, so stopping the ADSP deadlocked (needed to stop it around sleep)

* Sat Oct 24 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- wcd934x: enable the speaker smart boost clock with bit 4 of
  BOOST_PATH_CTL (as in lpass-wsa-macro) instead of bit 0; the register
  read back 0x00 during playback, so the WSA881x boost control was never
  driven (candidate cause of the very low speaker level)

* Mon Oct 19 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- spi-hid: wait up to two seconds for the touchscreen to become ready
  instead of failing requests with -ENODEV right after it is opened (iptsd
  could not start once nothing else kept the touchscreen open)
- Device tree: lid switch (Hall sensor for the Type Cover, TLMM GPIO 121,
  as in Windows' ACPI LID0); closing the cover can suspend, opening wakes
- pinctrl-sc8180x: enable the PDC dual-edge wake IRQ workaround (as on
  SM8150/SDM845); without it the lid switch only saw the cover opening

* Mon Oct 19 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- Device tree: sensor DSP (SLPI) with its FastRPC channel (sdsp); enable
  CONFIG_QCOM_FASTRPC. Accelerometer and magnetometer work with hexagonrpcd
  and libssc (tools/setup-sensors.sh)

* Sun Oct 18 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- Separate SLIMbus width overrides for the codec channel definition
  (snd_soc_wcd934x.spx_rx_bps) and the ADSP port (q6afe-dai spx_slim_bits)

* Sun Oct 18 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- Audio: SMMU stream IDs from the Windows IORT (SLIMbus 0x1b46/0x1b4d-0x1b51,
  q6asm 0x1b21); debug patches moved to kernel/debug-patches (not applied)
- snd-soc-sdm845: be_bits module parameter (16/24) to test the SLIMbus
  sample width between the DSP and the codec

* Sat Oct 17 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- SLIMbus/BAM: step logging through the DMA setup; spx_stop=3 stops before
  the BAM is started

* Sat Oct 17 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- SLIMbus NGD: step-by-step debug logging and the spx_stop module parameter
  (default 1 stops before the first register access, which kept freezing)

* Fri Oct 16 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- Add audio device tree nodes (WCD9340, WSA881x, APR, SLIMbus); experimental

* Thu Oct 15 2026 Surface Pro X Fedora kit <spx@localhost> - %{kversion}-%{krelease}
- Local build of linux-surface spx kernel for Fedora
