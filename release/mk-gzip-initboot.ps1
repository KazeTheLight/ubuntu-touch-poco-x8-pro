# mk-gzip-initboot.ps1 - rebuild init_boot with a *gzip* initramfs.
#
# Why: the kernel log (pstore/ramoops) finally showed what happens:
#     Trying to unpack rootfs image as initramfs...
#     rootfs image is not initramfs (no cpio magic); looks like an initrd
#     Run /init as init process      <- this was Android's init from vendor_boot
# So the kernel could not read our concatenated legacy-LZ4 streams, /init came
# from the stock vendor ramdisk instead, and Android's init aborted on the
# missing selinuxfs (our kernel has SELinux off) -> reboot to bootloader.
#
# This script decompresses every LZ4 stream, concatenates the raw cpio archives
# and compresses the result once with gzip -9, which the kernel's initramfs
# unpacker has always supported.
#
#   .\mk-gzip-initboot.ps1 [-Source images\ut_init_boot_lean.img]
#
# Output: images\ut_init_boot_gz.img

[CmdletBinding()]
param(
    [string]$Source = "",
    [string]$Out    = "",
    [string]$Lz4    = "C:\Users\Kaze\AppData\Local\Temp\opencode\lz4\lz4.exe"
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $HERE "images\ut_init_boot_lean.img" }
if (-not $Out)    { $Out    = Join-Path $HERE "images\ut_init_boot_gz.img" }
if (-not (Test-Path $Lz4)) { throw "lz4 not found: $Lz4" }

function Say($m) { Write-Host $m }
function Invoke-Lz4([string[]]$argv) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try { $null = & $Lz4 @argv 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    return $code
}

$src = [System.IO.File]::ReadAllBytes($Source)
if ([System.Text.Encoding]::ASCII.GetString($src,0,8) -ne "ANDROID!") { throw "not an Android boot image" }
$rs = [int][BitConverter]::ToUInt32($src,12)
Say "source       : $Source"
Say "ramdisk_size : $rs"

$ram = New-Object byte[] $rs
[Array]::Copy($src, 4096, $ram, 0, $rs)

# locate every legacy-LZ4 stream inside the ramdisk
$starts = New-Object System.Collections.ArrayList
$i = 0
while ($i -lt $rs - 4) {
    if ($ram[$i] -eq 2 -and $ram[$i+1] -eq 0x21 -and $ram[$i+2] -eq 0x4C -and $ram[$i+3] -eq 0x18) {
        [void]$starts.Add([int]$i); $i += 4
    } else { $i++ }
}
Say ("streams      : {0} at {1}" -f $starts.Count, ($starts -join ", "))
if ($starts.Count -lt 1) { throw "no LZ4 stream found" }

$tmp = Join-Path $env:TEMP ("klee-gz-" + (Get-Date -Format "HHmmss"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$allCpio = New-Object System.IO.MemoryStream
for ($k = 0; $k -lt $starts.Count; $k++) {
    $a = [int]$starts[$k]
    $b = if ($k + 1 -lt $starts.Count) { [int]$starts[$k+1] } else { $rs }
    $len = $b - $a
    $inF  = Join-Path $tmp "s$k.lz4"
    $outF = Join-Path $tmp "s$k.cpio"
    [System.IO.File]::WriteAllBytes($inF, $ram[$a..($b-1)])
    if ((Invoke-Lz4 @("-d","-f",$inF,$outF)) -ne 0) { throw "lz4 -d failed on stream $k" }
    $cp = [System.IO.File]::ReadAllBytes($outF)
    Say ("  stream {0}: {1,9} compressed -> {2,9} cpio" -f $k, $len, $cp.Length)
    $allCpio.Write($cp, 0, $cp.Length)
}
$raw = $allCpio.ToArray()
Say ("total cpio   : {0} bytes" -f $raw.Length)

# sanity: cpio archives start with 070701 / 070702 and end with TRAILER!!!
$s = [System.Text.Encoding]::GetEncoding(28591).GetString($raw)
if (-not $s.StartsWith("070701")) { throw "concatenated data does not start with a newc header" }
$trailers = ([regex]::Matches($s, 'TRAILER!!!')).Count
Say ("TRAILER!!!   : {0} (expected one per stream)" -f $trailers)
foreach ($probe in @("scripts/halium","sbin/parse-android-dynparts","bin/busybox","scripts/panic/telnet")) {
    Say ("  contains {0,-28} : {1}" -f $probe, $s.Contains($probe))
}

# gzip -9
$ms = New-Object System.IO.MemoryStream
$gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
$gz.Write($raw, 0, $raw.Length); $gz.Dispose()
$packed = $ms.ToArray()
Say ("gzip         : {0} bytes (was {1} lz4)" -f $packed.Length, $rs)

# rebuild the boot image
$partSize = $src.Length
$outBytes = New-Object byte[] $partSize
$hdr = New-Object byte[] 4096
[Array]::Copy($src, 0, $hdr, 0, 4096)
[Array]::Copy([BitConverter]::GetBytes([uint32]$packed.Length), 0, $hdr, 12, 4)
[Array]::Copy($hdr, 0, $outBytes, 0, 4096)
if (4096 + $packed.Length -gt $partSize - 64) { throw "ramdisk does not fit the partition" }
[Array]::Copy($packed, 0, $outBytes, 4096, $packed.Length)
[Array]::Copy($src, $partSize - 64, $outBytes, $partSize - 64, 64)   # keep AVB footer
[System.IO.File]::WriteAllBytes($Out, $outBytes)

# verify by decompressing what we just wrote
$chk = [System.IO.File]::ReadAllBytes($Out)
$chkRs = [int][BitConverter]::ToUInt32($chk,12)
$back = New-Object System.IO.MemoryStream
$inMs = New-Object System.IO.MemoryStream($chk, 4096, $chkRs, $false)
$gzi  = New-Object System.IO.Compression.GZipStream($inMs, [System.IO.Compression.CompressionMode]::Decompress)
$gzi.CopyTo($back); $gzi.Dispose()
$rt = $back.ToArray()
Say ""
Say "wrote        : $Out"
Say ("  size       : {0}" -f $chk.Length)
Say ("  ramdisk_sz : {0}" -f $chkRs)
Say ("  gzip magic : {0:x2} {1:x2}" -f $chk[4096], $chk[4097])
Say ("  round-trip : {0} bytes (must equal {1}) -> {2}" -f $rt.Length, $raw.Length, $(if ($rt.Length -eq $raw.Length) { "OK" } else { "MISMATCH" }))
Say ("  footer     : '{0}'" -f [System.Text.Encoding]::ASCII.GetString($chk, $chk.Length-64, 4))

$vrs = 60752308
$limit = 67108864
Say ""
Say ("vendor_boot(stock) {0} + init {1} = {2}   limit {3}" -f $vrs, $chkRs, ($vrs+$chkRs), $limit)
if (($vrs + $chkRs) -lt $limit) { Say ("  FITS, headroom {0} bytes" -f ($limit - ($vrs+$chkRs))) }
else { Say ("  OVER by {0} bytes" -f (($vrs+$chkRs) - $limit)) }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
