# mk-prebuilt-ut.ps1 - build UT boot images from the LineageOS klee prebuilt
# kernel blob (github.com/xiaomi-klee-devs/android_device_xiaomi_klee-kernel).
#
# Why: the generic kernel this port used ships no MediaTek MT6899 clock driver,
# so the UFS PHY failed with "Failed to get clk 'unipro'" and there was no
# storage at all (panic: "no data partition"). The LineageOS blob contains the
# vendor kernel (6.6.102-android15-8) and all 246 vendor modules built for it,
# including clk-mt6899.ko, mtk-scpsys-mt6899.ko, phy-mtk-ufs.ko and
# ufs-mediatek-mod.ko.
#
# Outputs (into release\images):
#   ut_boot_vendor.img        kernel only, header v4
#   ut_vendor_boot_vendor.img vendor ramdisk (all modules) + stock platform DTB
#
#   .\mk-prebuilt-ut.ps1

[CmdletBinding()]
param(
    [string]$Repo = "C:\Users\Kaze\AppData\Local\Temp\opencode\klee-kernel-prebuilt\extracted\android_device_xiaomi_klee-kernel-lineage-24.0",
    [string]$OutDir = "",
    [string]$Lz4 = "C:\Users\Kaze\AppData\Local\Temp\opencode\lz4\lz4.exe"
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = Join-Path $HERE "images" }
if (-not (Test-Path $Repo)) { throw "prebuilt repo not found: $Repo" }
if (-not (Test-Path $Lz4))  { throw "lz4 not found: $Lz4" }

function Say($m) { Write-Host $m }
function U32($b, $o) { [BitConverter]::ToUInt32($b, $o) }

function Invoke-Lz4([string[]]$argv) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try { $null = & $Lz4 @argv 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    return $code
}

# ------------------------------------------------------------------ cpio writer
$script:ino = 300000
function New-CpioEntry([string]$Name, [int]$Mode, [byte[]]$Data) {
    $ms = New-Object System.IO.MemoryStream
    $namesize = $Name.Length + 1
    $hdr = "070701" +
           ("{0:x8}" -f $script:ino) +
           ("{0:x8}" -f $Mode) +
           ("{0:x8}" -f 0) + ("{0:x8}" -f 0) +
           ("{0:x8}" -f 1) + ("{0:x8}" -f 0) +
           ("{0:x8}" -f $Data.Length) +
           ("{0:x8}" -f 0) + ("{0:x8}" -f 0) + ("{0:x8}" -f 0) + ("{0:x8}" -f 0) +
           ("{0:x8}" -f $namesize) + ("{0:x8}" -f 0)
    $hb = [System.Text.Encoding]::ASCII.GetBytes($hdr)
    $ms.Write($hb, 0, $hb.Length)
    $nb = [System.Text.Encoding]::ASCII.GetBytes($Name)
    $ms.Write($nb, 0, $nb.Length); $ms.WriteByte(0)
    $pad = (4 - (($hb.Length + $namesize) % 4)) % 4
    for ($i = 0; $i -lt $pad; $i++) { $ms.WriteByte(0) }
    if ($Data.Length) { $ms.Write($Data, 0, $Data.Length) }
    $pad2 = (4 - ($Data.Length % 4)) % 4
    for ($i = 0; $i -lt $pad2; $i++) { $ms.WriteByte(0) }
    $script:ino++
    return $ms.ToArray()
}

# --------------------------------------------------------------- boot image v4
function New-BootImage([byte[]]$Kernel, [int]$PartSize, [string]$Path) {
    $ms = New-Object System.IO.MemoryStream
    $hdr = New-Object byte[] 4096
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes("ANDROID!"), 0, $hdr, 0, 8)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$Kernel.Length), 0, $hdr, 8, 4)   # kernel_size
    [Array]::Copy([BitConverter]::GetBytes([uint32]0), 0, $hdr, 12, 4)               # ramdisk_size
    [Array]::Copy([BitConverter]::GetBytes([uint32]0), 0, $hdr, 16, 4)               # os_version
    [Array]::Copy([BitConverter]::GetBytes([uint32]1584), 0, $hdr, 20, 4)            # header_size
    [Array]::Copy([BitConverter]::GetBytes([uint32]4), 0, $hdr, 40, 4)               # header_version
    # cmdline at 44 stays zero (moved to vendor_cmdline)
    $ms.Write($hdr, 0, 4096)
    $ms.Write($Kernel, 0, $Kernel.Length)
    $pad = (4096 - ($Kernel.Length % 4096)) % 4096
    for ($i = 0; $i -lt $pad; $i++) { $ms.WriteByte(0) }
    $bytes = $ms.ToArray()
    if ($bytes.Length -gt $PartSize) { throw "boot image does not fit: $($bytes.Length) > $PartSize" }
    $out = New-Object byte[] $PartSize
    [Array]::Copy($bytes, 0, $out, 0, $bytes.Length)
    [System.IO.File]::WriteAllBytes($Path, $out)
    return $bytes.Length
}

# ------------------------------------------------------------- vendor_boot v4
function New-VendorBoot([byte[]]$VendorRamdisk, [byte[]]$Dtb, [string]$Cmdline, [string]$Path) {
    $page = 4096
    $headerSize = 2128
    $ms = New-Object System.IO.MemoryStream
    $hdr = New-Object byte[] $page
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes("VNDRBOOT"), 0, $hdr, 0, 8)
    [Array]::Copy([BitConverter]::GetBytes([uint32]4), 0, $hdr, 8, 4)          # header_version
    [Array]::Copy([BitConverter]::GetBytes([uint32]$page), 0, $hdr, 12, 4)     # page_size
    [Array]::Copy([BitConverter]::GetBytes([uint32]0x40000000), 0, $hdr, 16, 4) # kernel_addr
    [Array]::Copy([BitConverter]::GetBytes([uint32]0x66f00000), 0, $hdr, 20, 4) # ramdisk_addr
    [Array]::Copy([BitConverter]::GetBytes([uint32]$VendorRamdisk.Length), 0, $hdr, 24, 4)
    $cb = [System.Text.Encoding]::ASCII.GetBytes($Cmdline)
    [Array]::Copy($cb, 0, $hdr, 28, $cb.Length)                                # cmdline[2048]
    [Array]::Copy([BitConverter]::GetBytes([uint32]0x47c80000), 0, $hdr, 2076, 4) # tags_addr
    [Array]::Copy([BitConverter]::GetBytes([uint32]$headerSize), 0, $hdr, 2096, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$Dtb.Length), 0, $hdr, 2100, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint64]0x47c80000), 0, $hdr, 2104, 8) # dtb_addr
    [Array]::Copy([BitConverter]::GetBytes([uint32]108), 0, $hdr, 2112, 4)     # table_size (1 entry)
    [Array]::Copy([BitConverter]::GetBytes([uint32]1), 0, $hdr, 2116, 4)       # num entries
    [Array]::Copy([BitConverter]::GetBytes([uint32]108), 0, $hdr, 2120, 4)     # entry size
    [Array]::Copy([BitConverter]::GetBytes([uint32]0), 0, $hdr, 2124, 4)       # bootconfig_size
    $ms.Write($hdr, 0, $page)

    $ms.Write($VendorRamdisk, 0, $VendorRamdisk.Length)
    $pad = (4096 - ($VendorRamdisk.Length % 4096)) % 4096
    for ($i = 0; $i -lt $pad; $i++) { $ms.WriteByte(0) }

    $ms.Write($Dtb, 0, $Dtb.Length)
    $pad = (4096 - ($Dtb.Length % 4096)) % 4096
    for ($i = 0; $i -lt $pad; $i++) { $ms.WriteByte(0) }

    # one vendor ramdisk table entry: platform type, empty name, board_id zeroed
    $ent = New-Object byte[] 108
    [Array]::Copy([BitConverter]::GetBytes([uint32]$VendorRamdisk.Length), 0, $ent, 0, 4)  # size
    [Array]::Copy([BitConverter]::GetBytes([uint32]0), 0, $ent, 4, 4)                      # offset
    [Array]::Copy([BitConverter]::GetBytes([uint32]1), 0, $ent, 8, 4)                      # type platform
    $ms.Write($ent, 0, 108)
    $pad = (4096 - (108 % 4096)) % 4096
    for ($i = 0; $i -lt $pad; $i++) { $ms.WriteByte(0) }

    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    return $ms.Length
}

# ---------------------------------------------------------------------- build
$vendorDir = Join-Path $Repo "vendor_ramdisk"
$imageLz4  = Join-Path $Repo "Image.lz4"
$modLoad   = Join-Path $Repo "modules.load.vendor_ramdisk"
foreach ($p in @($vendorDir, $imageLz4, $modLoad)) { if (-not (Test-Path $p)) { throw "missing $p" } }

Say "packing vendor ramdisk ..."
$mods = Get-ChildItem $vendorDir -File | Sort-Object Name
Say ("  {0} modules, {1:N2} MB" -f $mods.Count, (($mods | Measure-Object Length -Sum).Sum/1MB))
$ms = New-Object System.IO.MemoryStream
foreach ($m in $mods) {
    $data = [System.IO.File]::ReadAllBytes($m.FullName)
    $e = New-CpioEntry -Name ("lib/modules/" + $m.Name) -Mode 0x81A4 -Data $data
    $ms.Write($e, 0, $e.Length)
}
$loadData = [System.IO.File]::ReadAllBytes($modLoad)
$e = New-CpioEntry -Name "lib/modules/modules.load" -Mode 0x81A4 -Data $loadData
$ms.Write($e, 0, $e.Length)
$e = New-CpioEntry -Name "TRAILER!!!" -Mode 0 -Data ([byte[]]@())
$ms.Write($e, 0, $e.Length)
$cpio = $ms.ToArray()
Say ("  cpio: {0:N2} MB" -f ($cpio.Length/1MB))

$tmpCpio = Join-Path $env:TEMP "vendor-md.cpio"
$tmpLz4  = Join-Path $env:TEMP "vendor-md.lz4"
[System.IO.File]::WriteAllBytes($tmpCpio, $cpio)
if (Test-Path $tmpLz4) { Remove-Item $tmpLz4 -Force }
if ((Invoke-Lz4 @("-l","-9","-f",$tmpCpio,$tmpLz4)) -ne 0) { throw "lz4 failed" }
$vram = [System.IO.File]::ReadAllBytes($tmpLz4)
Say ("  compressed: {0:N2} MB" -f ($vram.Length/1MB))

# kernel: LK on this device expects the *legacy* LZ4 payload (stock boot.img and
# every working build start with 02 21 4c 18). The blob ships a modern LZ4 frame
# (04 22 4d 18), so decompress it and recompress in legacy format.
$tmpRaw = Join-Path $env:TEMP "vendor-kernel-raw.img"
$tmpLeg = Join-Path $env:TEMP "vendor-kernel-legacy.lz4"
if ((Invoke-Lz4 @("-d","-f",$imageLz4,$tmpRaw)) -ne 0) { throw "kernel decompress failed" }
if (Test-Path $tmpLeg) { Remove-Item $tmpLeg -Force }
if ((Invoke-Lz4 @("-l","-9","-f",$tmpRaw,$tmpLeg)) -ne 0) { throw "kernel recompress failed" }
$kraw = [System.IO.File]::ReadAllBytes($tmpLeg)
Say ("kernel payload (legacy lz4): {0:N2} MB, magic {1:x2} {2:x2} {3:x2} {4:x2}" -f `
    ($kraw.Length/1MB), $kraw[0], $kraw[1], $kraw[2], $kraw[3])

$dtbPath = Join-Path (Split-Path -Parent $HERE) "port\prebuilt_dtb.img"
$dtb = [System.IO.File]::ReadAllBytes($dtbPath)
Say ("dtb: {0:N0} bytes" -f $dtb.Length)

$bootOut = Join-Path $OutDir "ut_boot_vendor.img"
$vndOut  = Join-Path $OutDir "ut_vendor_boot_vendor.img"
$n1 = New-BootImage -Kernel $kraw -PartSize 67108864 -Path $bootOut
$n2 = New-VendorBoot -VendorRamdisk $vram -Dtb $dtb -Cmdline "printk.devkmsg=on" -Path $vndOut
Say ""
Say ("wrote {0}  ({1:N0} bytes used)" -f $bootOut, $n1)
Say ("wrote {0}  ({1:N0} bytes)" -f $vndOut, $n2)
Say ""
$initSize = [int][BitConverter]::ToUInt32([System.IO.File]::ReadAllBytes((Join-Path $OutDir "ut_init_boot.img")), 12)
Say ("budget: vendor {0:N0} + init {1:N0} = {2:N0}  limit {3:N0}  |  {4}" -f `
    $vram.Length, $initSize, ($vram.Length + $initSize), 67108864,
    $(if (($vram.Length + $initSize) -lt 67108864) { "FITS" } else { "OVER by " + (($vram.Length + $initSize) - 67108864) }))
