<#
.SYNOPSIS
    Export what Windows knows about the Surface Pro X hardware, for Linux bring-up.

.DESCRIPTION
    Run this in Windows on the Surface Pro X, in an elevated PowerShell:

        Set-ExecutionPolicy -Scope Process Bypass
        .\Collect-SurfaceProXInfo.ps1

    It writes SurfaceProX-windows-info-<date>.zip to your Desktop with:
      - every present device: name, class, hardware IDs, ACPI path, driver
      - ACPI tables (DSDT and friends from the registry; all tables, including
        SSDTs, if acpidump.exe from Intel's ACPICA tools is next to this script
        or on PATH)
      - the .inf files of all installed drivers
      - the folders of the Qualcomm audio, camera, sensor and DSP drivers
        (configuration and calibration files that describe the hardware)

    Nothing is changed on the system. Serial numbers are not collected.
    The driver files belong to Microsoft/Qualcomm: share the zip for debugging,
    but don't post it publicly.

.PARAMETER IncludeBinaries
    Also copy driver binaries (.sys, .dll, .exe, .mbn, .elf, .cat). They are
    not needed for analysis and make the zip much larger.

.PARAMETER SkipDriverFiles
    Only collect the device list and ACPI tables (small zip).
#>
[CmdletBinding()]
param(
    [switch]$IncludeBinaries,
    [switch]$SkipDriverFiles
)

$ErrorActionPreference = 'Continue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error 'Run this from an elevated PowerShell (right-click > Run as administrator).'
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$name = "SurfaceProX-windows-info-$stamp"
$root = Join-Path $env:TEMP $name
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Green }

# ---- system ---------------------------------------------------------------
Write-Step 'System information'
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor
[ordered]@{
    Manufacturer   = $cs.Manufacturer
    Model          = $cs.Model
    SystemSKU      = $cs.SystemSKUNumber
    Processor      = ($cpu | Select-Object -First 1).Name
    MaxClockMHz    = ($cpu | Select-Object -First 1).MaxClockSpeed
    MemoryGB       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    BiosVersion    = $bios.SMBIOSBIOSVersion
    BiosDate       = $bios.ReleaseDate
    WindowsVersion = "$($os.Caption) $($os.Version) build $($os.BuildNumber)"
    Architecture   = $env:PROCESSOR_ARCHITECTURE
} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $root 'system.json')

# ---- devices ----------------------------------------------------------------
Write-Step 'Device list (this takes a minute)'
$keys = @(
    'DEVPKEY_Device_HardwareIds',
    'DEVPKEY_Device_CompatibleIds',
    'DEVPKEY_Device_LocationPaths',
    'DEVPKEY_Device_BiosDeviceName',
    'DEVPKEY_Device_LocationInfo',
    'DEVPKEY_Device_Parent',
    'DEVPKEY_Device_Service',
    'DEVPKEY_Device_DriverInfPath',
    'DEVPKEY_Device_DriverVersion',
    'DEVPKEY_Device_DriverProvider',
    'DEVPKEY_Device_Manufacturer'
)
$devices = foreach ($d in Get-PnpDevice -PresentOnly) {
    $props = @{}
    try {
        Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $keys -ErrorAction Stop |
            ForEach-Object { $props[$_.KeyName -replace '^DEVPKEY_Device_', ''] = $_.Data }
    } catch { }
    [pscustomobject]@{
        Name          = $d.FriendlyName
        Class         = $d.Class
        Status        = $d.Status
        InstanceId    = $d.InstanceId
        AcpiPath      = $props['BiosDeviceName']
        HardwareIds   = ($props['HardwareIds'] -join '; ')
        CompatibleIds = ($props['CompatibleIds'] -join '; ')
        LocationPaths = ($props['LocationPaths'] -join '; ')
        LocationInfo  = $props['LocationInfo']
        Parent        = $props['Parent']
        Service       = $props['Service']
        DriverInf     = $props['DriverInfPath']
        DriverVersion = $props['DriverVersion']
        DriverVendor  = $props['DriverProvider']
        Manufacturer  = $props['Manufacturer']
    }
}
$devices | Sort-Object Class, Name | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $root 'devices.csv')
$devices | Sort-Object Class, Name | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 (Join-Path $root 'devices.json')
$devices | Where-Object { $_.AcpiPath } | Sort-Object AcpiPath |
    Format-Table -AutoSize AcpiPath, Class, Name, Service |
    Out-String -Width 300 | Set-Content -Encoding UTF8 (Join-Path $root 'acpi-device-map.txt')

pnputil /enum-drivers | Out-File -Encoding UTF8 (Join-Path $root 'drivers-installed.txt')
Get-CimInstance Win32_SoundDevice | Select-Object Name, Manufacturer, Status, PNPDeviceID |
    Format-List | Out-File -Encoding UTF8 (Join-Path $root 'sound-devices.txt')

# ---- ACPI tables ------------------------------------------------------------
Write-Step 'ACPI tables'
$acpiDir = Join-Path $root 'acpi'
New-Item -ItemType Directory -Force -Path $acpiDir | Out-Null
foreach ($table in 'DSDT', 'FADT', 'FACS', 'RSDT') {
    $base = "HKLM:\HARDWARE\ACPI\$table"
    if (-not (Test-Path $base)) { continue }
    Get-ChildItem $base -Recurse | ForEach-Object {
        $key = $_
        foreach ($valueName in $key.GetValueNames()) {
            $data = $key.GetValue($valueName)
            if ($data -is [byte[]]) {
                $relKey = $key.Name.Substring($key.Name.IndexOf("\$table\") + $table.Length + 2)
                $fileName = ("$table-$relKey-$valueName" -replace '[^\w.-]', '_') + '.bin'
                [IO.File]::WriteAllBytes((Join-Path $acpiDir $fileName), $data)
            }
        }
    }
}
$acpidump = $null
$local = Join-Path $PSScriptRoot 'acpidump.exe'
if (Test-Path $local) {
    $acpidump = (Get-Item $local).FullName
} elseif (Get-Command acpidump.exe -ErrorAction SilentlyContinue) {
    $acpidump = (Get-Command acpidump.exe).Source
}
if ($acpidump) {
    Push-Location $acpiDir
    & $acpidump -b 2>&1 | Out-File -Encoding UTF8 'acpidump-log.txt'
    & $acpidump -o 'all-tables.txt' 2>&1 | Out-Null
    Pop-Location
} else {
    Write-Host '    acpidump.exe not found: only DSDT/FADT/FACS/RSDT exported.' -ForegroundColor Yellow
    Write-Host '    For SSDTs too, put acpidump.exe (Intel ACPICA Windows tools) next to this script.' -ForegroundColor Yellow
}

# ---- driver files ------------------------------------------------------------
if (-not $SkipDriverFiles) {
    Write-Step 'Driver .inf files'
    $store = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    $infDir = Join-Path $root 'driver-infs'
    New-Item -ItemType Directory -Force -Path $infDir | Out-Null
    Get-ChildItem $store -Directory | ForEach-Object {
        Get-ChildItem $_.FullName -Filter *.inf -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $infDir ("{0}__{1}" -f $_.Directory.Name, $_.Name)) }
    }

    Write-Step 'Audio, camera, sensor and DSP driver folders'
    # Qualcomm driver package name prefixes for the subsystems we want to bring up.
    $patterns = @(
        'qcadsp*', 'qcaud*', 'qcwcd*', 'qcsoundwire*', 'qcslimbus*', 'qcacdb*', 'qcsubsys*',
        'qccam*', 'qcmscam*', 'qccamera*', 'qcsensors*', 'qcsns*', 'qcsensor*',
        'qcmpss*', 'qcwwan*', 'qcmbb*', 'qcpil*', 'qcremotefs*', 'qcsmd*',
        'surfaceaudio*', 'surfacecamera*', '*ov[0-9]*', '*imx[0-9]*',
        # Surface Pro X specific packages: audio calibration (acsp), codec,
        # cameras, sensors, subsystems.
        'surfaceprox_*', 'surfacelightsensor*', 'surfacedigitizer*'
    )
    # Program code and signatures aren't needed to read the hardware setup;
    # configuration, calibration (.acdb) and tuning files are what matter.
    $binaryExtensions = @('.sys', '.dll', '.exe', '.mbn', '.elf', '.cat', '.mui', '.pdb')
    $drvDir = Join-Path $root 'driver-folders'
    New-Item -ItemType Directory -Force -Path $drvDir | Out-Null
    $folders = Get-ChildItem $store -Directory | Where-Object {
        $n = $_.Name; ($patterns | Where-Object { $n -like $_ }).Count -gt 0
    }
    foreach ($f in $folders) {
        # Skip the large DSP/modem images; the firmware kit already handles those.
        $dest = Join-Path $drvDir $f.Name
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Get-ChildItem $f.FullName -Recurse -File |
            Where-Object { $_.Length -lt 20MB } |
            Where-Object { $IncludeBinaries -or $_.Extension -notin $binaryExtensions } |
            ForEach-Object {
                $rel = $_.FullName.Substring($f.FullName.Length).TrimStart('\')
                $target = Join-Path $dest $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
                Copy-Item $_.FullName $target
            }
    }
    $folders | Select-Object Name | Out-File -Encoding UTF8 (Join-Path $root 'driver-folders-copied.txt')
}

# ---- pack -------------------------------------------------------------------
Write-Step 'Creating zip'
$zip = Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.zip"
# Compress-Archive in Windows PowerShell 5.1 stores paths with backslashes,
# which other systems extract as flat file names. Build the zip directly.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $zip) { Remove-Item -Force $zip }
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem $root -Recurse -File | ForEach-Object {
        $entry = $_.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $_.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
}
Remove-Item -Recurse -Force $root
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ''
Write-Host "Saved: $zip ($size MB)" -ForegroundColor Green
