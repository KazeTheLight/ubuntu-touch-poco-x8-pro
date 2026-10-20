# mk-single-lz4-initboot.ps1 - one legacy-LZ4 stream, exactly like stock.
#
# Evidence chain:
#   * stock init_boot  = 1 x LZ4-legacy stream  -> Android boots
#   * stock vendor_boot= 1 x LZ4-legacy stream
#   * our lean image   = 2 x LZ4-legacy streams -> kernel: "no cpio magic"
#   * our gzip image   = 1 x gzip member        -> kernel: "Decoding failed"
#     (gzip was recognised, but the vendor LZ4 blob that follows is not a
#      second gzip member, so gunzip aborts)
# Halium's build appends the klee overlay as a *second* stream; the stock
# bootloader/kernel combination on this device only tolerates the layout stock
# Android uses. So: decompress both streams, concatenate the cpio archives and
# compress them back into ONE stream.
#
#   .\mk-single-lz4-initboot.ps1
#
# Output: images\ut_init_boot_one.img

[CmdletBinding()]
param(
    [string]$Source = "",
    [string]$Out    = "",
    [string]$Lz4    = "C:\Users\Kaze\AppData\Local\Temp\opencode\lz4\lz4.exe"
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $HERE "images\ut_init_boot_lean.img" }
if (-not $Out)    { $Out    = Join-Path $HERE "images\ut_init_boot_one.img" }
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

$starts = New-Object System.Collections.ArrayList
$i = 0
while ($i -lt $rs - 4) {
    if ($ram[$i] -eq 2 -and $ram[$i+1] -eq 0x21 -and $ram[$i+2] -eq 0x4C -and $ram[$i+3] -eq 0x18) {
        [void]$starts.Add([int]$i); $i += 4
    } else { $i++ }
}
Say ("streams      : {0} at {1}" -f $starts.Count, ($starts -join ", "))
if ($starts.Count -lt 1) { throw "no LZ4 stream found" }

$tmp = Join-Path $env:TEMP ("klee-one-" + (Get-Date -Format "HHmmss"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$all = New-Object System.IO.MemoryStream
for ($k = 0; $k -lt $starts.Count; $k++) {
    $a = [int]$starts[$k]
    $b = if ($k + 1 -lt $starts.Count) { [int]$starts[$k+1] } else { $rs }
    $inF  = Join-Path $tmp "s$k.lz4"
    $outF = Join-Path $tmp "s$k.cpio"
    [System.IO.File]::WriteAllBytes($inF, $ram[$a..($b-1)])
    if ((Invoke-Lz4 @("-d","-f",$inF,$outF)) -ne 0) { throw "lz4 -d failed on stream $k" }
    $cp = [System.IO.File]::ReadAllBytes($outF)
    Say ("  stream {0}: {1,9} -> {2,9} cpio" -f $k, ($b-$a), $cp.Length)
    $all.Write($cp, 0, $cp.Length)
}
$raw = $all.ToArray()
Say ("total cpio   : {0}" -f $raw.Length)
$s = [System.Text.Encoding]::GetEncoding(28591).GetString($raw)
if (-not $s.StartsWith("070701")) { throw "concatenated data does not start with a newc header" }
foreach ($probe in @("scripts/halium","bin/busybox","scripts/panic/telnet")) {
    Say ("  contains {0,-24} : {1}" -f $probe, $s.Contains($probe))
}

$rawF = Join-Path $tmp "all.cpio"
$oneF = Join-Path $tmp "one.lz4"
[System.IO.File]::WriteAllBytes($rawF, $raw)
if ((Invoke-Lz4 @("-l","-9","-f",$rawF,$oneF)) -ne 0) { throw "lz4 -l failed" }
$packed = [System.IO.File]::ReadAllBytes($oneF)
Say ("lz4 (1 strm): {0} bytes (was {1})" -f $packed.Length, $rs)
Say ("  magic      : {0:x2} {1:x2} {2:x2} {3:x2}" -f $packed[0],$packed[1],$packed[2],$packed[3])

$partSize = $src.Length
$outBytes = New-Object byte[] $partSize
$hdr = New-Object byte[] 4096
[Array]::Copy($src, 0, $hdr, 0, 4096)
[Array]::Copy([BitConverter]::GetBytes([uint32]$packed.Length), 0, $hdr, 12, 4)
[Array]::Copy($hdr, 0, $outBytes, 0, 4096)
if (4096 + $packed.Length -gt $partSize - 64) { throw "ramdisk does not fit the partition" }
[Array]::Copy($packed, 0, $outBytes, 4096, $packed.Length)
[Array]::Copy($src, $partSize - 64, $outBytes, $partSize - 64, 64)
[System.IO.File]::WriteAllBytes($Out, $outBytes)

# verify: decompress our own output and compare
$chk = [System.IO.File]::ReadAllBytes($Out)
$chkRs = [int][BitConverter]::ToUInt32($chk,12)
$vF = Join-Path $tmp "verify.lz4"
$vC = Join-Path $tmp "verify.cpio"
[System.IO.File]::WriteAllBytes($vF, $chk[4096..(4096+$chkRs-1)])
if ((Invoke-Lz4 @("-d","-f",$vF,$vC)) -ne 0) { throw "verification decompress failed" }
$back = [System.IO.File]::ReadAllBytes($vC)
Say ""
Say "wrote        : $Out"
Say ("  size       : {0}" -f $chk.Length)
Say ("  ramdisk_sz : {0}" -f $chkRs)
Say ("  round-trip : {0} vs {1} -> {2}" -f $back.Length, $raw.Length, $(if ($back.Length -eq $raw.Length) { "OK" } else { "MISMATCH" }))
Say ("  footer     : '{0}'" -f [System.Text.Encoding]::ASCII.GetString($chk, $chk.Length-64, 4))
Say ("  streams in ramdisk: {0}" -f (((@(0..($chkRs-4) | Where-Object { $chk[4096+$_] -eq 2 -and $chk[4097+$_] -eq 0x21 -and $chk[4098+$_] -eq 0x4C -and $chk[4099+$_] -eq 0x18 })).Count)))

$vrs = 60752308; $limit = 67108864
Say ""
Say ("vendor {0} + init {1} = {2}  limit {3}" -f $vrs, $chkRs, ($vrs+$chkRs), $limit)
if (($vrs + $chkRs) -lt $limit) { Say ("  FITS, headroom {0}" -f ($limit - ($vrs+$chkRs))) } else { Say ("  OVER by {0}" -f (($vrs+$chkRs)-$limit)) }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
