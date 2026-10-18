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
