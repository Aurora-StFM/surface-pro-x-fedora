# Pass fwversion and fwsource with --define (see build-firmware.sh).

%global debug_package %{nil}
%global __os_install_post %{nil}
# The remote-processor firmware files are ARM ELF images; they are data for
# the DSPs, not programs for this system, so allow them in a noarch package.
%global _binaries_in_noarch_packages_terminate_build 0

Name:           surface-pro-x-firmware
Version:        %{fwversion}
Release:        1
Summary:        Firmware for the Microsoft Surface Pro X (SQ1/SQ2)
# Microsoft/Qualcomm firmware with no explicit redistribution license.
# Build this package yourself for a device you own.
License:        LicenseRef-Proprietary
URL:            https://github.com/linux-surface/aarch64-firmware
Source0:        surface-pro-x-firmware.tar
BuildArch:      noarch
AutoReqProv:    no

%description
Remote processor (modem/WiFi, audio DSP, compute DSP), GPU, WiFi board data
and Bluetooth firmware for the Surface Pro X, built from %{fwsource}.
Overrides for files Fedora's linux-firmware also ships are installed under
/usr/lib/firmware/updates, which the kernel searches first.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}

%install
cp -a . %{buildroot}/
# Own our files and the directories we create; leave shared parents alone.
(
    cd %{buildroot}
    find usr/lib/firmware \( -type f -o -type l \) | sed 's|^|/|'
    find usr/lib/firmware/updates usr/lib/firmware/qcom/msft -type d | sed 's|^|%dir /|'
) > %{_builddir}/firmware-files.list

%files -f %{_builddir}/firmware-files.list

%changelog
* Thu Oct 15 2026 Surface Pro X Fedora kit <spx@localhost> - %{fwversion}-1
- Local build
