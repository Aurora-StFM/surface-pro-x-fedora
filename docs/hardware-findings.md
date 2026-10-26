# Surface Pro X (SQ1) hardware findings

From the Windows exports of 16 October 2026 (`SurfaceProX-windows-info-20261016-085630.zip` and `-121025.zip`, the second with the Surface driver folders), the decompiled DSDT, the Windows driver INFs and calibration files, the ADSP firmware, and the linux-surface `spx/v6.18.3` device tree.

## Device

| | |
|---|---|
| Model | Surface Pro X, SKU `Surface_Pro_X_1876` (2019, Wi-Fi + LTE) |
| SoC | Microsoft SQ1 (SC8180X), 3.0 GHz, Adreno 685 |
| RAM | 16 GB |
| UEFI | 4.234.140 |
| ACPI DSDT | `QCOMM SDM8180` rev 3 |

Pin numbers match: Windows `\_SB.GIO0` pins are the same as Linux `tlmm` pins. For example, the touch interrupt is pin 122 and the light-sensor interrupt is pin 24 in both the DSDT and the Linux device tree. That means GPIOs from the DSDT can be copied directly.

## Audio: the same design as the Lenovo Yoga C630

This changes the plan the most. The Surface Pro X uses the same audio design as the SDM850 Lenovo Yoga C630, which already has working audio in mainline Linux (`sdm850-lenovo-yoga-c630.dts`).

Evidence:

- **Codec:** a Qualcomm WCD934x ("Aqstic") on SLIMbus. The Windows codec driver `qcauddev8180.inf` says its settings are shared with the 850: *"MinorVersion - 1 for 8998 and 2 for 850 and 8180"*. The settings include the WCD934x DSP (`IsWDSPAvailable`), headset button detection (`IsMBHCReq`), and `SlaveInfo = 2`, which most likely means two speaker amplifiers on the codec's SoundWire bus. The C630 has the same setup: 2 × WSA8810.
- **SLIMbus controller:** the DSDT node `\_SB.ADSP.SLM1` sits at `0x171C0000` with GIC interrupt 0xC3, which is SPI 163. That address and interrupt are exactly the SDM845 `slim-ngd@171c0000`.
- **SLIMbus DMA (BAM):** `0x17184000`, interrupt 0xC4 (SPI 164). This also matches SDM845's `slimbam`.
- **Second SLIMbus:** `SLM2` at `0x17240000`, interrupt 0x143. It is probably the SLIMbus to the Bluetooth/FM chip, which isn't needed for speakers or microphones.
- **Codec device `AUDD`:**
  - reset GPIO: tlmm 143 (the C630 uses tlmm 64)
  - interrupt: `GIO0` pin 0x100 (256), which is outside the 190 TLMM pins (open question 1 below)
  - control bus: SPI on `\_SB.SPI4` = `0x0088C000`, which is `spi3` in `sc8180x.dtsi`, at 24 MHz on chip select 0 (open question 2 below)
- **Speaker protection** is turned on in Windows (`SpeakerProtectionParameters`), and Windows ships tuning files for each audio route: `Speaker_cal.acdb`, `Headset_cal.acdb` and others in `surfaceprox_acsp`. Linux's Qualcomm audio driver doesn't use these files.

### Confirmed by the second export

- **Codec model:** the audio calibration files (`Codec_cal.acdb`, `Speaker_cal.acdb`) name the codec `WCD9340.1.0`, the exact codec the C630 uses.
- **Speakers:** the calibration files list stereo speakers (`SPEAKER_PHONE_SPKR_STEREO`) with current/voltage feedback (`SPEAKER_VI`), which matches two WSA881x smart amplifiers with speaker protection.
- **Microphones:** digital microphones (DMIC 1–6 combinations). They connect to the WCD9340, the same as on the C630.
- **Audio DSP interface:** the `qcadsp8180.mbn` firmware uses APR and the Elite framework (`apr_list.c`, `apr_log.c`, no GPR). Its library maps are named `map_AVS_SHARED_LIBS_845`, so it's the SDM845 audio DSP software line. Linux's `qcom,apr-v2` and q6afe/q6asm/q6adm services are the right choice. This answers open question 3.
- **Codec clock (MCLK):** the power configuration in the DSDT (`\_SB.PEP0`) turns on `PPP_RESOURCE_ID_CXO_BUFFERS_BBCLK2_A` for the codec. That is `RPMH_LN_BB_CLK2`, the same clock `sdm845-wcd9340.dtsi` uses.
- **Codec power:** the same power configuration turns on `LDO14_E` at 1.8 V (1,800,000 µV) for the codec. The Surface Pro X device tree doesn't describe that regulator yet, so a `vreg_l14e_1p8` (ldo14 on PMIC "e") has to be added and used for the `vdd-*` supplies. The C630 uses `vreg_s4a_1p8`.
- **Reset pin:** the codec's `GpioIo` line is tlmm 143. It's output-capable (`IoRestrictionNone`), which fits a reset line; the power configuration has no other GPIO for the codec.
- **Interrupt pin: TLMM 123.** Windows gives some interrupts "direct-connect" numbers above 255. The rule is that 0x100 + 0x40·k selects interrupt k + 1 in `\_SB.GIO0._CRS`. Three devices list their physical pin as well, and all three fit: the lid (0x140 → GIC 0x259 → PDC 89 → GPIO 121, matching its `GpioIo`), the embedded controller (0x1C0 → GIC 0x293 → PDC 112 → GPIO 180, which matches the Linux device tree) and the embedded controller's second line (0x200 → GIC 0x223 → PDC 35 → GPIO 133). For the codec, 0x100 → GIC 0x25B (SPI 571) → PDC 91 → **GPIO 123**. The SDM845 value, TLMM 54, is the touchscreen reset on this device, so it was never an option.
- **Camera module files:** `com.surface.sensormodule.*.bin` are Qualcomm Chromatix files. They contain the sensors' I2C addresses (`slaveAddr`) and power-up sequences, but their format still needs decoding.
- **Modem storage (EFS):** `\_SB.RFS0` gets its memory windows from values UEFI fills in at boot (`RMTB`, `RFMB`, `RFAB`). The DSDT doesn't show where the real EFS data lives, so linux-surface issue #2 stays open.

### What the Linux side needs

Nearly all of this is copying existing SDM845/C630 code:

Implemented in `kernel/patches/0001-arm64-dts-qcom-sc8180x-surface-pro-x-Add-audio-WCD93.patch`, plus a UCM profile in the support package. Neither is tested on hardware yet.

1. **`sc8180x.dtsi`** (the chip description):
   - add `apr` (`qcom,apr-v2`, `apr_audio_svc`) under `remoteproc_adsp` → `glink-edge`, with the q6core, q6afe, q6asm and q6adm audio services, as in `sdm845.dtsi`
   - add the `slimbam` DMA controller at `0x17184000` and `slim-ngd@171c0000`, both with the SDM845 values
   - the SMMU stream IDs differ from SDM845's and still need to be found (open question 4 below)
2. **`sc8180x-surface-pro-x.dts`** (the device description):
   - include `sdm845-wcd9340.dtsi`, or copy it
   - set the codec reset GPIO to tlmm 143
   - add the two speakers on the codec's SoundWire bus, `swm`
   - add the sound card node, based on the C630's
3. **Kernel driver:** add an `sc8180x` compatible string to `sound/soc/qcom/sdm845.c`, or reuse `qcom,sdm845-sndcard`.
4. **User space:** add an ALSA UCM profile based on the C630's in `alsa-ucm-conf`. This also caps the speaker volume, because there's no speaker protection.

### Open questions (the Linux diagnostics run will answer most of these)

1. ~~Codec interrupt.~~ Decoded: TLMM 123 (see above). Still needs to be confirmed on hardware.
2. **SPI or SLIMbus for codec control.** Windows registers the codec on SPI. Linux's `wcd934x` driver controls the codec over SLIMbus, the way the C630 does. The chip supports both, so SLIMbus should work.
3. ~~Audio DSP interface: APR or GPR.~~ Answered: APR (see above).
4. **SMMU stream IDs** for SLIMbus DMA and the audio DSP. These come from trial and error or from the Windows IORT table. Collecting all tables with `acpidump.exe` would help here.

## Cameras

| ACPI device | Sensor | Linux sensor driver |
|---|---|---|
| `\_SB.CAMF` (front) | OmniVision OV5693, `MSHW0180` | `ov5693` (mainline) |
| `\_SB.CAMS` (rear) | OmniVision OV13858, `MSHW0181` | `ov13858` (mainline) |
| `\_SB.CAMI` (IR, Windows Hello) | OmniVision OV7251, `MSHW0182` | `ov7251` (mainline) |

All three sensors already have Linux drivers, and they're the same sensors other Surface models use. What's missing is the SC8180X camera block itself: the ISP is Spectra 390, `\_SB.VFE0`, `\_SB.MPCS`, `\_SB.CAMP`. Mainline has no `camss` support for SC8180X; the closest supported chips are SM8250 and SC8280XP. The sensors' I2C addresses and power-up steps are in Windows tuning files (`com.surface.sensormodule.*.bin`) rather than in the DSDT. Cameras are still the hardest item.

## Other devices

- **Light sensor:** `MSHW0184` at I2C2 address 0x39, interrupt tlmm 24. This matches the device tree's TODO note that it's an AMS TCS3430 rather than the APDS9960 the tree describes. Mainline Linux has no TCS3430 driver. It would be a small new IIO driver.
- **Touch and pen:** `MSHW0134` on `\_SB.SPI2`, interrupt tlmm 122, with a reset line on the PMIC GPIO controller. This already matches the device tree (`hid-over-spi`). Multitouch only needs iptsd.
- **LTE:** a Snapdragon X24 modem built into the SoC (`\_SB.AMSS`). Linux can already start the modem's processor, because WiFi runs through it. The cellular side additionally needs ModemManager over QRTR, and probably the real modem data partitions (EFS), see linux-surface issue #2.
- **Second SSD PCIe link:** `\_SB.PCI0/PCI2/PCI3` are the PCIe controllers; this matches the device tree's TODO note about the two-PHY setup.

## Windows export script fixes made after this run

- **Zip paths:** the zip is now built with forward slashes. Windows PowerShell 5.1's `Compress-Archive` stored backslashes, so other systems extracted every file as one flat name.
- **Driver folders:** `surfaceprox_*`, `surfacelightsensor*` and `surfacedigitizer*` are now copied. Running it again collects the codec config, the speaker calibration files and the camera tuning folders, which this run missed.

## Audio bring-up log (16 Oct 2026, kernel 6.18.3-2)

- ADSP firmware `qcadsp8180.mbn` boots when started after the root filesystem is mounted: "remote processor adsp is now up", APR services 4:3, 4:4, 4:7 and 4:8 appear, and the q6asm DAIs join an IOMMU group. APR is confirmed.
- With `slim_qcom_ngd_ctrl` unloaded, the ADSP runs stably.
- With it loaded, the machine hard-locks right after the PDR "audio_pd" up indication. The lockup comes when the NGD driver brings up the controller after the QMI handshake, before any SLIMbus error is printed.
- Kernel 6.18.3-3 adds step logging (`spx-dbg:`) and the `spx_stop` module parameter to find the exact step.
- Kernel 6.18.3-3 results:
  - QMI select-instance (ADSP as master) and the power request both succeed.
  - The SLIMbus registers are readable: the version register is 0x02020000 (NGD v2.2), NGD_STATUS is 0x0000040c, and the NGD config register is 0.
  - The lockup happens in `qcom_slim_ngd_init_dma` (BAM at 0x17184000).
- Kernel 6.18.3-4 logs every BAM pipe register access to tell a blocked register from a DMA/IOMMU fault.
- 6.18.3-4 results:
  - The BAM pipe 3 registers are all accessible, and the pipe enables.
  - No master-capability message ever arrives over RX DMA.
  - The machine locks up either during the RX DMA start or on the later pipe teardown. This points at DMA through the SMMU with the wrong stream ID.
- Stream IDs: SM8150, the same generation as SC8180X with identical PCIe SIDs, uses 0x1b23-0x1b25 for its ADSP fastrpc banks. SDM845 uses 0x1823/0x1824. The LPASS SIDs therefore look shifted from 0x18xx to 0x1bxx, so the patch now uses 0x1b06 for SLIMbus/BAM and 0x1b21 for q6asm. Both are still unverified on hardware.
- 0x1b06 also locks up. The Windows IORT (18 Oct dump) gives the real IDs. Node `\_SB.ADSP.SLM1.ADCM` maps:
  - 0x1b21
  - 0x1b46
  - 0x1b4d-0x1b51
  - 0x1b53
  - 0x1b58
  - 0x1b5c-0x1b5e

  This matches the downstream SM8150 layout: slim_aud 0x1b46 / 0x1b4d / 0x1b50, slim_qca 0x1b53, audio ION 0x1b21. The patch now gives slimbam and slim-ngd 0x1b46 + 0x1b4d-0x1b51, and q6asm 0x1b21.
- Other IORT mappings, for later:
  - ADSP fastrpc 0x1b23-0x1b25 (`\_SB.ARPC`)
  - USB audio offload 0x1b2f (`\_SB.USBA`)
  - QUP 0x4c3 / 0x603 / 0x7a3
  - IPA 0x520-0x522
- **Audio works** (18 Oct 2026) with the IORT stream IDs. The path is now confirmed:
  - SLIMbus master capability is received.
  - wcd934x is found: chip id 0x108 / minor 0x1, version 0x401.
  - The WSA881x speakers enumerate on the codec's SoundWire bus.
  - Playback works through q6asm.
- Open issues:
  - Speaker level is very low at maximum.
  - MBHC reports "MONO plug type detected" with ramp errors at probe, which may mean a false jack detection.
  - The first stream gets "Memory_map_regions failed", then later ones work.
  - The WSA881x speakers go UNATTACHED/reattach around stream stop.
- The WSA881x speaker amplifiers runtime-suspend after each stream (log: "Slave N state check1: UNATTACHED"). Once, the left amplifier (sdw ...:00:3) failed to resume: `snd_soc_pcm_component_pm_runtime_get` returned -22 and all playback failed while the ADSP was still running. Support 1.7 forbids runtime PM on the amplifiers through udev. Pops come only from the right amplifier. Swapped SD_N GPIOs (wcdgpio 1/2) compared with the C630 are still a candidate cause.
- WSA881x live register read (regmap debugfs cache_bypass, during playback, 18 Oct):
  - Left (sdw ...:00:3) has the rev 2.0 init sequence applied: BIAS_INT 0x5f, BOOST_PRESET_OUT1 0xb7, BONGO_RESRV 0x5e/0x07.
  - Right (...:00:4) still has reset values there (0x00, 0x77, 0xb2/0x05). The init patch was not re-applied after a re-attach, which is a likely cause of the right-only pops and buzzing.
  - Both amplifiers otherwise show PA on (DRV_EN 0xfc), DRV_GAIN 0x09 (18 dB), boost enabled (0x98), DAC on, and no INTR_STATUS flags. The amplifier side looks configured, so the low level probably comes from upstream (digital data level).
- One "SWR Port collision detected" and some "SWR CMD error"s at the first stream start, not on later starts.
- Raising "RX7/RX8 Digital Volume" by +16 dB makes playback audible but crackly and "dirty". The data arriving at the codec or the amplifiers is corrupted, not just low in level. Suspects:
  - the SLIMbus sample width/packing between this ADSP firmware and the codec (test with snd_soc_sdm845.be_bits=24, kernel 6.18.3-5)
  - SoundWire port timing (port collision seen once)
- 18 Oct 2026, kernel 6.18.3-6: every SLIMbus width combination other than 16/16 hangs playback, with no audio and no DSP error:
  - DSP 24 / codec 16
  - DSP 16 / codec 24
  - both 24
  
  16/16 plays but very quietly. The width mismatch theory is therefore unconfirmed; 16/16 is the only consistent configuration.
- Swapping the WSA SD_N GPIOs made things worse (init failures, write overflows, reversed attach order). The C630 assignment (left wcdgpio 1, right wcdgpio 2) is correct.
- Keeping the codec's SoundWire master out of runtime PM (`wcd934x-soundwire*/power/control = on`) stops the WSA UNATTACHED/re-attach cycles.
- Open issue: speaker output is about 40-50 dB too low at the WSA input, and coarse when digitally boosted. Not explained by PA gain, the compander or the boost. Remaining suspects: SoundWire frame/port parameters (port collision and CMD errors seen) and DSP-side processing (no ACDB calibration).

## Bluetooth

- The WCN3998 (QCA, SoC version 0x40010224) loads crbtfw01.tlv and crnv01.bin fine, but it has no public BD address. `btmgmt info` lists 0 controllers and bluetoothctl reports "No default controller available".
- Setting an address with `btmgmt --index 0 public-addr` makes it work (confirmed 18 Oct 2026).
- Support 1.7 does this at boot through a udev rule and the oneshot surface-pro-x-bt-address.service. The address comes from /etc/surface-pro-x/bluetooth-address, or is derived from /etc/machine-id as a locally administered unicast address.
- The cleaner long-term fix would be a `local-bd-address` in the device tree filled by the bootloader, but the Surface UEFI doesn't do that.

## Quick checks of the linux-surface "to be done" list (18 Oct 2026, SQ1 with LTE)

| Issue | Result |
|---|---|
| #29 Suspend | `s2idle` only (`mem_sleep: [s2idle]`). Suspend and resume work. |
| #41 UEFI ResetSystem | Reboot and power-off both work, many times over. |
| #37 TrEE | qseecom 0x1401001 found, `qcom.tz.uefisecapp` client set up, efivarfs mounted rw with 96 variables. UEFI variable access works. |
| #38 Sensors | `apds9960` (ambient light/proximity) shows up as an IIO device, but `monitor-sensor` reports nothing. The motion sensors live behind the SLPI sensor DSP, which has no remoteproc node. |
| #23 Cameras | No video or media devices; CAMSS and the sensors are not in the device tree. |
| #27 External displays | Only eDP-1; the DP controllers are disabled in the device tree. |
| #22 LTE | The modem DSP runs and offers a full QMI set over QRTR: WDS 1, NAS 3, DMS 2, UIM 11, WMS 5, Voice 9, IPA control 49, Location 16. ModemManager finds no modem: there is no QRTR control port or IPA data path yet. |
| #39 GPS | The modem offers the QMI Location service (16, "PDS v2"). |

## Sensors (SLPI), from the Windows driver store (19 Oct 2026)

- **Windows reads:** accelerometer, gyroscope, compass/magnetometer, inclinometer, orientation and light, all through `\_SB.SEN2` (QCOM049F, "All-Ways Aware Hub"). The ambient light sensor is `\_SB.I2C2.ACSD` (MSHW0184, the apds9960 on i2c2, which Linux already sees).
- **Chips,** from the `surfaceprox_sensorsconfig` registry JSONs:
  - ST LSM6DSO (accelerometer and gyroscope)
  - AKM AK991x (magnetometer)
  - ADI ADUX1080 (display-side proximity)
- **Firmware:** `qcslpi8180.mbn` from `surfaceprox_subextscss`. It is a relocatable ELF (segment flags bit 27) spanning 0x97300000-0x98700000 (20 MiB), the same as SM8150's `slpi_mem`. The Surface DT already reserves `scss_mem` at 0x99000000 with exactly that size, so the image is loaded there.
- **Device tree:** `0004-…-Add-SLPI-sensor-DSP.patch` adds `remoteproc_slpi` at 0x02400000 using the SM8150 wiring:
  - wdog SPI 494, glink SPI 170, apss_shared 24
  - LCX/LMX power domains
  - smp2p-slpi already present in sc8180x.dtsi, with the same SPI 172 and mbox 26 as SM8150
  
  The SM8150 ADSP/CDSP wiring is identical in sc8180x.dtsi, which supports this assumption. fastrpc is left out until the DSP boots.
- **Plan after the DSP boots:** fastrpc (sdsp), then hexagonrpcd serving the sensor registry/config JSONs, then libssc + iio-sensor-proxy, as postmarketOS does on SDM845 phones.
- **19 Oct 2026, the SLPI boots.** "remote processor slpi is now up" with the 0004 DT and the firmware loaded into scss_mem. No freeze, and the other DSPs are unaffected.
  - qrtr node 9 offers service 400 (Snapdragon Sensor Core) and 4100, plus the usual SSCTL, servreg, TMD and CoreSight services.
  - The IORT entry `\_SB.SEN1` maps 0x5a1-0x5a3, identical to SM8150's sdsp fastrpc compute banks, so 0004 now adds the sdsp fastrpc node with those IDs. CONFIG_QCOM_FASTRPC=m was added to fedora.config.
  - Next: hexagonrpcd on /dev/fastrpc-sdsp to serve the sensor registry/config JSONs from the Windows package, then libssc and iio-sensor-proxy (ssc).
- **19 Oct 2026, the IMU works on Linux.** Setup:
  - SLPI running
  - hexagonrpcd (linux-msm/hexagonrpc 0.5) on /dev/fastrpc-sdsp with `-d sdsp -s`
  - root /usr/share/qcom/sc8180x/Microsoft/SurfaceProX containing:
    - sensors/config/ (the Windows JSONs and config_list.txt)
    - an empty sensors/registry/
    - socinfo/ (hw_platform CLS, soc_id 340, … from the Windows package)
  
  `libssc` 0.4.4 `ssccli`:
  - accelerometer: |g| about 9.8 m/s², follows tilt
  - magnetometer: about 128 µT, uncalibrated
  - proximity and light: "Unable to initialize … UNKNOWN". The ALS is the apds9960 on i2c2, not on the SSC. The ADUX1080 isn't reachable through libssc's proximity type yet.
  
  The SLPI parses the configs and repeatedly tries to write registry files under /persist/sensors/registry/registry/ (hexagonrpcd is read-only), but the sensors work from its in-memory registry anyway.
- **Next:** iio-sensor-proxy built with libssc support (screen rotation in KDE), a hexagonrpcd service, SLPI autostart, and packaging (hexagonrpc, libssc) in the kit.

## Touchscreen and pen (iptsd)

- Digitizer: `hid-over-spi` on spi0.0 (SPI1, IRQ GPIO 122), HID ID `001C:045E:0996`, exposed as one hidraw node plus several `spi 045E:0996` input devices (single-touch fallback mode, including a "Stylus" one).
- iptsd 3.1.1 (built as an RPM on the device) recognises it, reads the screen size from the device's metadata and runs in touchscreen mode. It creates "IPTSD Virtual Touchscreen/Stylus 045E:0996" uinput devices on the virtual bus (0x06).
- With iptsd running, the native single-touch devices still deliver events, so every contact was counted twice. Fixed by `LIBINPUT_IGNORE_DEVICE` on the bus 0x1c event devices.
- spi-hid powers the digitizer down on the last close and, on the next open, rejects raw requests (`spi_hid_ll_raw_request called in unready state`, -ENODEV) until the digitizer has answered its reset. iptsd and `iptsd-check-device` send `HIDIOCGFEATURE` straight after opening, so:
  - iptsd's udev check fails at boot, its `iptsd@.service` is never started, and the `dev-hidrawN.device` unit is not registered (starting `iptsd@` by hand stops immediately because of `BindsTo=`).
  - It only worked at first because libinput kept the native input devices open; hiding them removed that.
  - Workaround: `surface-pro-x-touch@.service` holds the hidraw node open, waits for `/sys/bus/spi/devices/spi0.0/ready`, then execs iptsd. Kernel patch 0005 makes spi-hid wait up to 2 s for ready.
- Stopping iptsd switches the digitizer back to single-touch mode. Running two iptsd instances on the same node made the digitizer send reports larger than the driver's buffer (`Bad body length 211 > 124`), after which spi-hid needed a power cycle (a warm reboot was not enough at least once).

## Lid switch (Type Cover closed)

- ACPI: `\_SB.LID0` (PNP0C0D). `_LID` returns `\_SB.GIO0.LIDR`, a GpioIo read of TLMM pin 0x79 (121), no pull; 1 = open. The change interrupt is `_AEI` pin 0x140 (edge, both, SharedAndWake), whose `_EVT` re-reads LIDR and notifies LID0.
- Same pin as the SC8180X reference design and the Lenovo Flex 5G (both use `gpio-keys` with `SW_LID` on `&tlmm 121 GPIO_ACTIVE_LOW`). GPIO 121 has a PDC wake mapping (PDC 89), so it can wake from suspend.
- Kernel patch 0006 adds that `gpio-keys` node (wake on open: `EV_ACT_DEASSERTED`).
- Test with the DTB alone: the `Lid` input device appears and GPIO 121 follows the cover (`high` open, `low` closed; the Type Cover's own KIP state reads `closed` at the same time), but no `SW_LID` events arrive. `/proc/interrupts` showed one interrupt per close/open cycle: GPIO 121 is routed through the PDC as a wake interrupt, and the SC8180X PDC (like SM8150/SDM845) only triggers on one edge of a dual-edge interrupt. pinctrl-sc8180x lacks `wakeirq_dual_edge_errata`, which makes pinctrl-msm switch the PDC polarity after each edge. Kernel patch 0007 sets it.

## Speaker level, 24 Oct 2026 (kernel 6.18.3-8)

- Codec pins (WCD gpiochip, 5 lines; 1 and 2 are the WSA SD_N lines) 0, 3 and 4 set high during playback: no change. The Flex 5G's "speaker battery via wcdgpio 4" switch is not what's missing here.
- Register dump during playback (tools/audio-dump.sh):
  - SoundWire: frame 48x16, master and slave port parameters agree (DP1 DAC, DP2 COMP, DP3 BOOST per amplifier, C630 values). Both amplifiers have DAC/COMP/BOOST ports on, PA 12 dB, smart boost preset 7.5 V.
  - Codec RX7/RX8: interpolators on at 48 kHz, digital volumes 0 dB, compander on, smart boost enabled in RX7/8_RX_PATH_CFG1 bit 0, **but CDC_BOOST0/1_BOOST_PATH_CTL (0x0c19/0x0c21) read 0x00**. The DAPM supply "SBOOSTn_CLK" in wcd934x.c uses bit 0; the clock enable is bit 4 (WCD934X_BOOST_PATH_CLK_EN_MASK, and the same block in lpass-wsa-macro enables BIT(4)). Kernel patch 0008 fixes the bit.
  - Reads from the WSA881x over SoundWire fail in this boot ("read FIFO underflow", "SWR CMD error", once "bus clash"), and the first stream prepare failed once ("DPN_PortCtrl register write failed", -5) before a retry worked. Writes are not acknowledged either, so configuration writes may be lost. Second open issue after 0008.
- **Cause of the low level found (24 Oct):** `speaker-test -D plughw:0,0` (S16_LE) plays at full, normal volume. PipeWire opened the same PCM with S24_LE (q6asm-dai offers S16_LE and S24_LE). This DSP firmware evidently treats the S24_LE container differently from the driver's assumption (the level drop is about 8 bits, -48 dB, with the coarse, crackly sound of the remaining low bits). Forcing PipeWire to S16LE (WirePlumber `audio.format`) gives normal levels. Support 1.9 ships that rule. A kernel-side fix would be to drop S24_LE from q6asm-dai for this platform or to send the 24-bit media format the firmware expects; not done.

## Graphics: GTK 4 corruption (24 Oct 2026)

- GTK 4.22.5 apps (e.g. Riff) draw with torn, displaced tiles. GTK 4 defaults to its Vulkan renderer; the device is "Turnip Adreno (TM) 680", Mesa 26.2.5. With `GSK_RENDERER=ngl` (OpenGL, freedreno "FD680", GL 4.6) they render correctly. Qt/KDE apps use OpenGL and were never affected.
- `TU_DEBUG=sysmem` (turnip renders without GMEM tiling) also fixes GTK 4 with Vulkan; `TU_DEBUG=noubwc` does not. So the corruption comes from turnip's GMEM/bin rendering on the a680. Worth reporting to Mesa.
- A system-wide `GSK_RENDERER=ngl` (environment.d) was tried and taken out again: media playback stopped working at the same time (not yet confirmed as the cause).
- Vesktop (Electron, Flatpak) shows the same kind of displaced tiles in the server banner. Not fixed by `FD_MESA_DEBUG=noubwc`/`nogmem`, `TU_DEBUG=sysmem` or `--disable-gpu-rasterization`; `--disable-gpu-compositing` fixes it but is very slow. Next to try: `--disable-features=WaylandOverlayDelegation`, `--ozone-platform=x11`.

## Silent playback through PipeWire (24 Oct 2026)

- After the big system update, all players hung or stayed silent. Direct ALSA playback (`aplay`, also with mmap and 512-frame periods) was audible; PipeWire's stream ran (hw_ptr advancing) but silent.
- Mixer diff with/without PipeWire: `RX INT7_1 MIX1 INP0` and `RX INT8_1 MIX1 INP0` go from RX0/RX1 to ZERO when PipeWire runs. The card reports `Headphone Jack` and `Headset Mic Jack` as plugged in (MBHC false detection, "MONO plug type detected" at boot; the Surface Pro X has no jack). PipeWire prefers the Headphones device (priority 200), and switching away from Speaker runs the wcd934x SpeakerDisableSeq, which disconnects the speaker interpolators.
- Support 1.10 removes the Headphones and headset Mic devices from the UCM profile. Follow-up: stop MBHC from reporting a jack in the first place (device tree/driver), then add the built-in microphones.
- The `Memory_map_regions failed` / `command[0x10dac] not expecting rsp` (ASM_DATA_CMD_READ_V2) messages came from PipeWire opening the headset-mic capture stream on that phantom jack.
- Second cause of silent apps: Fedora's WirePlumber now routes app streams through media-role loopback sinks ("Multimedia", "Notification", ...; `media-role-nodes.conf`). The "Multimedia" one was muted, so Firefox played silently while KDE's speaker test (which goes to the device directly) worked. Unmuting it / setting it to 100 % in the KDE volume applet fixed Firefox.
- The system-wide `GSK_RENDERER=ngl` turned out not to be involved in the playback problem; per-app `flatpak override --user --env=GSK_RENDERER=ngl <app>` is the simplest way to keep GTK 4 apps on OpenGL.

## Sleep with audio running (25 Oct 2026)

- s2idle suspend works with the ADSP stopped (resume fine; the SLPI restarts itself on resume). With the ADSP running, the journal ends at "PM: suspend entry (s2idle)" and the machine can't be woken.
- Workaround in support 1.10: a systemd-sleep hook stops the user PipeWire units and the ADSP before suspend, and after resume restarts the ADSP, absorbs the failing first stream with a short aplay, and starts PipeWire again (in the background via systemd-run).
- Stopping the ADSP at runtime (`echo stop > .../state`) deadlocks: `qcom_slim_ngd_ssr_pdr_notify()` holds `tx_lock` while `qcom_slim_ngd_down()` reports the codec absent; the codec teardown (`wcd_mbhc_deinit` → `free_irq` → regmap write over SLIMbus) calls `qcom_slim_ngd_xfer_msg()`, which takes `tx_lock` again ("task tee is blocked on a mutex likely owned by task tee"). Kernel patch 0009 sets the DOWN state under the lock but tears down outside it, and makes transfers fail with -ENETDOWN while DOWN. The first version (kernel-spx 6.18.3-10) refused transfers whenever the state was DOWN, which also blocked the capability exchange at ADSP start ("SLIM: capability TX failed:-100", no sound card). 6.18.3-11 uses a separate teardown flag instead. The sleep hook needs 6.18.3-11 or later.
- With kernel 6.18.3-11 and the hook active, sleep and wake work. After the ADSP restart the codec comes back, but the sound card isn't assembled again (one "ASoC: CODEC DAI ... not registered" attempt, nothing deferred, no retry). Unbinding and binding the card driver (`/sys/bus/platform/drivers/msm-snd-sdm845`, device `sound`) brings it back. Support 1.11 and `start-audio.sh` do that automatically when the card is missing.
- Support 1.11 still hung on the next test: screen off, keyboard backlight on. The journal showed "Freezing user space processes failed after 20 seconds" with `surface-pro-x-audio-sleep` in D state in `wcd934x_slim_status` (`slim_report_absent` during `rproc_shutdown`), then systemd-sleep retrying suspend over and over. Cause: systemd-sleep freezes `user.slice` *before* it runs system-sleep hooks, so the hook's `systemctl --user stop pipewire…` couldn't work. PipeWire kept `/dev/snd/*` open, and the codec removal on ADSP stop takes the sound card down, which waits for all open card files. Support 1.12 moves this to `surface-pro-x-audio-sleep.service` (`Before=sleep.target`, `StopWhenUnneeded=yes`, ExecStart stops, ExecStop restores after resume), which runs while user sessions are still live, and closes any remaining `/dev/snd` users before stopping the ADSP.

## Touch after sleep (25 Oct 2026)

- After resume spi-hid logs "Failed to receive header: -108" and runs its error handler (device reset). The touchscreen comes back in single-touch mode while iptsd keeps running, so multitouch is lost. Restarting iptsd switches it back. Support 1.13 adds `surface-pro-x-touch-resume.service` (same `Before=sleep.target` / `StopWhenUnneeded` pattern as the audio sleep service) that restarts `surface-pro-x-touch@*` after resume.
