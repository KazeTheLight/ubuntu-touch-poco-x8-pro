# mk-lean-initboot.ps1 - rebuild ut_init_boot.img with the Halium initramfs
# trimmed so that vendor_ramdisk + init_boot ramdisk fits LK's 64 MiB
# mb_ramdisk on this device (see expdb: "ramdisk_map_sz cannot overrun").
#
# Only ONE file is dropped: usr/lib/aarch64-linux-gnu/libcrypto.so.1.1
# (nlink=1, not a hardlink parent, ~2.1 MB raw / ~1.1 MB compressed).
#
# The image keeps: the ANDROID! header, the kernel-less layout, the klee
# overlay stream and the AVB footer of the source image.
#
#   .\mk-lean-initboot.ps1 [-Drop <name>[,<name>...]]
#
# Output: images\ut_init_boot_lean.img

[CmdletBinding()]
param(
    [string]$Source = "",
    [string]$Out    = "",
    [string[]]$Drop = @("usr/lib/aarch64-linux-gnu/libcrypto.so.1.1"),
    [string]$Lz4    = "C:\Users\Kaze\AppData\Local\Temp\opencode\lz4\lz4.exe"
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $HERE "images\ut_init_boot.img" }
if (-not $Out)    { $Out    = Join-Path $HERE "images\ut_init_boot_lean.img" }
if (-not (Test-Path $lz4)) { throw "lz4 not found: $Lz4" }

function Say($m) { Write-Host $m }

function Invoke-Lz4([string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try { $null = & $Lz4 @argv 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    return $code
}

# ---------------------------------------------------------------- read source
$src = [System.IO.File]::ReadAllBytes($Source)
if ([System.Text.Encoding]::ASCII.GetString($src,0,8) -ne "ANDROID!") { throw "not an Android boot image" }
$rs = [BitConverter]::ToUInt32($src, 12)
Say "source        : $Source"
Say "ramdisk_size  : $rs"

# split the ramdisk into its concatenated legacy-LZ4 streams (the kernel walks
# them one after another: halium archive, then the klee overlay archive)
$ram = New-Object byte[] $rs
[Array]::Copy($src, 4096, $ram, 0, $rs)
$magic = [byte[]](0x02,0x21,0x4C,0x18)
$streams = New-Object System.Collections.ArrayList
$i = 0
while ($i -lt $rs - 4) {
    $hit = $false
    while ($i -lt $rs - 4) {
        if ($ram[$i] -eq 2 -and $ram[$i+1] -eq 0x21 -and $ram[$i+2] -eq 0x4C -and $ram[$i+3] -eq 0x18) { $hit = $true; break }
        $i++
    }
    if (-not $hit) { break }
    [void]$streams.Add([int]$i)
    $i += 4
}
Say "lz4 streams   : $($streams.Count) at $($streams -join ', ')"
if ($streams.Count -lt 1) { throw "no legacy LZ4 stream found" }

# ------------------------------------------------------- decompress stream 0
$s0 = [int]$streams[0]
$s0len = [int]$(if ($streams.Count -gt 1) { $streams[1] - $s0 } else { $rs - $s0 })
$tmpDir = Join-Path $env:TEMP ("klee-lean-" + (Get-Date -Format "HHmmss"))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$lz0 = Join-Path $tmpDir "s0.lz4"
$cp0 = Join-Path $tmpDir "s0.cpio"
[System.IO.File]::WriteAllBytes($lz0, $ram[$s0..($s0+$s0len-1)])
if ((Invoke-Lz4 @("-d","-f",$lz0,$cp0)) -ne 0) { throw "lz4 -d failed" }
$cpio = [System.IO.File]::ReadAllBytes($cp0)
Say "halium cpio   : $($cpio.Length) bytes"

# ------------------------------------------------------------- parse + filter
$s = [System.Text.Encoding]::GetEncoding(28591).GetString($cpio)
$p = 0; $ents = [ordered]@{}; $dropped = @()
while ($p -lt $cpio.Length - 110) {
    if ($s.Substring($p,6) -ne "070701") { throw "bad cpio magic at $p" }
    $fs   = [Convert]::ToInt32($s.Substring($p+54,8),16)
    $ns   = [Convert]::ToInt32($s.Substring($p+94,8),16)
    $name = $s.Substring($p+110, $ns-1)
    if ($name -eq "TRAILER!!!") { break }
    $ds = $p + 110 + $ns; $ds += (4 - ($ds % 4)) % 4
    if ($Drop -contains $name) { $dropped += $name }
    else { $ents[$name] = [pscustomobject]@{Hdr=$s.Substring($p,110+$ns); Size=$fs; Off=$ds} }
    $p = $ds + $fs; $p += (4 - ($p % 4)) % 4
}
$trailerStart = $p
$tns = [Convert]::ToInt32($s.Substring($trailerStart+94,8),16)
$tlen = 110 + $tns; $tlen += (4 - ($tlen % 4)) % 4
$trailer = $s.Substring($trailerStart, $tlen)
Say "entries kept  : $($ents.Count)   dropped: $($dropped.Count)"
foreach ($d in $Drop) {
    if ($dropped -notcontains $d) { Say "  WARNING: '$d' not found in the archive" }
    else { Say "  dropped: $d" }
}
if ($dropped.Count -eq 0) { throw "nothing was dropped - refusing to write an identical image" }

# ------------------------------------------------------------ rebuild stream 0
$ms = New-Object System.IO.MemoryStream
foreach ($k in $ents.Keys) {
    $e = $ents[$k]
    $hb = [System.Text.Encoding]::GetEncoding(28591).GetBytes($e.Hdr)
    $ms.Write($hb, 0, $hb.Length)
    if ($e.Size -gt 0) { $ms.Write($cpio, $e.Off, $e.Size) }
    $pad = (4 - ($e.Size % 4)) % 4
    for ($q = 0; $q -lt $pad; $q++) { $ms.WriteByte(0) }
}
$tb = [System.Text.Encoding]::GetEncoding(28591).GetBytes($trailer)
$ms.Write($tb, 0, $tb.Length)
$newCpio = $ms.ToArray()
Say "new cpio      : $($newCpio.Length) bytes (was $($cpio.Length))"

$newCpioPath = Join-Path $tmpDir "new.cpio"
$newLz4Path  = Join-Path $tmpDir "new.lz4"
[System.IO.File]::WriteAllBytes($newCpioPath, $newCpio)
if ((Invoke-Lz4 @("-l","-9","-f",$newCpioPath,$newLz4Path)) -ne 0) { throw "lz4 -l failed" }
$newLz4 = [System.IO.File]::ReadAllBytes($newLz4Path)
Say "new stream0   : $($newLz4.Length) bytes (was $s0len)"

# ------------------------------------------------------- reassemble ramdisk
$rest = New-Object System.Collections.ArrayList
for ($k = 1; $k -lt $streams.Count; $k++) {
    $a = [int]$streams[$k]
    $b = [int]$(if ($k + 1 -lt $streams.Count) { $streams[$k+1] } else { $rs })
    [void]$rest.Add(@($a, ($b - $a)))
}
$newRamLen = [int]$newLz4.Length
foreach ($r in $rest) { $newRamLen += [int]$r[1] }
$newRam = New-Object byte[] $newRamLen
[Array]::Copy($newLz4, 0, $newRam, 0, $newLz4.Length)
$off = $newLz4.Length
foreach ($r in $rest) {
    [Array]::Copy($ram, $r[0], $newRam, $off, $r[1])
    $off += $r[1]
}
Say "new ramdisk   : $($newRam.Length) bytes (was $rs)  saved $($rs - $newRam.Length)"

# --------------------------------------------------------------- write image
$partSize = $src.Length
$outBytes = New-Object byte[] $partSize
$hdr = [byte[]]$src[0..4095]
[Array]::Copy([System.BitConverter]::GetBytes([uint32]$newRam.Length), 0, $hdr, 12, 4)
[Array]::Copy($hdr, 0, $outBytes, 0, 4096)
[Array]::Copy($newRam, 0, $outBytes, 4096, $newRam.Length)
# keep the AVB footer (last 64 bytes) so the structure stays the same
[Array]::Copy($src, $partSize - 64, $outBytes, $partSize - 64, 64)
[System.IO.File]::WriteAllBytes($Out, $outBytes)

# ------------------------------------------------------------------ verify
$chk = [System.IO.File]::ReadAllBytes($Out)
$chkRs = [BitConverter]::ToUInt32($chk, 12)
Say ""
Say "wrote         : $Out"
Say "  size        : $($chk.Length)"
Say "  magic       : $([System.Text.Encoding]::ASCII.GetString($chk,0,8))"
Say "  ramdisk_size: $chkRs"
Say "  footer      : $([System.Text.Encoding]::ASCII.GetString($chk, $chk.Length-64, 4))"
$vrs = 60752308           # stock klee vendor_boot, offset 24
$limit = 67108864
Say ""
Say "vendor_boot(stock) ramdisk : $vrs"
Say "init_boot lean ramdisk     : $chkRs"
Say "total                      : $($vrs + $chkRs)   limit: $limit"
if (($vrs + $chkRs) -lt $limit) {
    Say ("  RESULT: FITS, headroom " + ($limit - ($vrs + $chkRs)) + " bytes") 
} else {
    Say ("  RESULT: STILL OVER by " + (($vrs + $chkRs) - $limit) + " bytes")
}
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
