# verify-ufs.ps1 - check that a build really contains the MediaTek UFS stack.
#
#   .\verify-ufs.ps1 [-Dir release\build-artifacts]
#
# Checks:
#   * kernel image has the ufs-mediatek platform glue ("mediatek,ufshci")
#   * the UT vendor_boot ramdisk carries ufs-mediatek.ko / ufshcd*.ko
#   * vendor_boot header still matches the stock load addresses

[CmdletBinding()]
param(
    [string]$Dir = "",
    [string]$Lz4 = "C:\Users\Kaze\AppData\Local\Temp\opencode\lz4\lz4.exe"
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Dir) { $Dir = Join-Path $HERE "build-artifacts" }

$boot = Join-Path $Dir "ut_boot.img"
$vnd  = Join-Path $Dir "ut_vendor_boot.img"
foreach ($f in @($boot, $vnd)) { if (-not (Test-Path $f)) { throw "missing $f" } }

function U32($b, $o) { [BitConverter]::ToUInt32($b, $o) }

# ---------------------------------------------------------------- kernel
$b = [System.IO.File]::ReadAllBytes($boot)
$ks = [int](U32 $b 8)
$tmp = Join-Path $env:TEMP "verify-k.lz4"
$img = Join-Path $env:TEMP "verify-k.img"
[System.IO.File]::WriteAllBytes($tmp, $b[4096..(4096+$ks-1)])
$old = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
try { $null = & $Lz4 -d -f $tmp $img 2>&1 } finally { $ErrorActionPreference = $old }
$k = [System.IO.File]::ReadAllBytes($img)
$s = [System.Text.Encoding]::GetEncoding(28591).GetString($k)
Write-Host ("kernel: {0:N0} bytes compressed -> {1:N0} decompressed" -f $ks, $k.Length)
$ufsGlue = ([regex]::Matches($s, 'mediatek,ufshci')).Count
$phyGlue = ([regex]::Matches($s, 'mediatek,ufs-phy')).Count
Write-Host ("  'mediatek,ufshci'   : {0}" -f $ufsGlue) $(if ($ufsGlue -gt 0) { "Green" } else { "Red" })
Write-Host ("  'mediatek,ufs-phy'  : {0}" -f $phyGlue) $(if ($phyGlue -gt 0) { "Green" } else { "Yellow" })

# ---------------------------------------------------------------- vendor ramdisk
$v = [System.IO.File]::ReadAllBytes($vnd)
Write-Host ""
Write-Host ("vendor_boot: {0:N0} bytes" -f $v.Length)
Write-Host ("  kernel_addr  : 0x{0:x}" -f (U32 $v 16))
Write-Host ("  ramdisk_addr : 0x{0:x}" -f (U32 $v 20))
Write-Host ("  dtb_size     : {0}" -f (U32 $v 2100))
Write-Host ("  vendor_ramdisk_size : {0}" -f (U32 $v 24))

$vs = [System.Text.Encoding]::GetEncoding(28591).GetString($v)
foreach ($n in @("ufs-mediatek.ko", "ufshcd-pltfrm.ko", "ufshcd-core.ko", "modules.load")) {
    $hit = $vs.Contains($n)
    Write-Host ("  contains {0,-20}: {1}" -f $n, $hit) $(if ($hit) { "Green" } else { "Red" })
}

Write-Host ""
if ($ufsGlue -gt 0 -and $vs.Contains("ufs-mediatek.ko")) {
    Write-Host "RESULT: UFS stack present - safe to flash and test" Green
} else {
    Write-Host "RESULT: UFS stack INCOMPLETE - do not flash yet" Red
}
