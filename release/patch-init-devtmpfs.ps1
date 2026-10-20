# patch-init-devtmpfs.ps1 - replace the devtmpfs mount in the UT initramfs with
# a tmpfs fallback.
#
# The LineageOS klee vendor kernel is built without CONFIG_DEVTMPFS (the string
# does not appear in the image at all), so the Debian initramfs stops at
#     mount -t devtmpfs -o nosuid,mode=0755 udev /dev
# and nothing is ever populated under /dev. Android copes because it uses tmpfs
# plus ueventd; systemd-udevd also creates the nodes itself when devtmpfs is
# absent, so mounting tmpfs is enough for the Halium initramfs.
#
#   .\patch-init-devtmpfs.ps1 -Source images\ut_init_boot_one2.img `
#                             -Out images\ut_init_boot_tmpfs.img

[CmdletBinding()]
param(
    [string]$Source = "",
    [string]$Out    = "",
    [string]$Lz4    = "C:\Users\Kaze\AppData\Local\Temp\opencode\lz4\lz4.exe"
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $HERE "images\ut_init_boot_one2.img" }
if (-not $Out)    { $Out    = Join-Path $HERE "images\ut_init_boot_tmpfs.img" }

function Say($m) { Write-Host $m }
function Invoke-Lz4([string[]]$argv) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try { $null = & $Lz4 @argv 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    return $code
}

$src = [System.IO.File]::ReadAllBytes($Source)
if ([System.Text.Encoding]::ASCII.GetString($src,0,8) -ne "ANDROID!") { throw "not a boot image" }
$rs = [int][BitConverter]::ToUInt32($src,12)
$ram = New-Object byte[] $rs
[Array]::Copy($src, 4096, $ram, 0, $rs)

# must be a single legacy-LZ4 stream
$start = -1
for ($i = 0; $i -lt $rs - 4; $i++) {
    if ($ram[$i] -eq 2 -and $ram[$i+1] -eq 0x21 -and $ram[$i+2] -eq 0x4C -and $ram[$i+3] -eq 0x18) { $start = $i; break }
}
if ($start -lt 0) { throw "no legacy lz4 stream" }
$tmpIn = Join-Path $env:TEMP "patch-in.lz4"
$tmpCpio = Join-Path $env:TEMP "patch.cpio"
[System.IO.File]::WriteAllBytes($tmpIn, $ram[$start..($rs-1)])
if ((Invoke-Lz4 @("-d","-f",$tmpIn,$tmpCpio)) -ne 0) { throw "decompress failed" }
$cb = [System.IO.File]::ReadAllBytes($tmpCpio)
$s = [System.Text.Encoding]::GetEncoding(28591).GetString($cb)
Say ("cpio: {0:N0} bytes" -f $cb.Length)

$oldLine = 'mount -t devtmpfs -o nosuid,mode=0755 udev /dev'
$newLine = 'mount -t devtmpfs -o nosuid,mode=0755 udev /dev 2>/dev/null || mount -t tmpfs -o nosuid,mode=0755 udev /dev'

function New-Entry([string]$hdr, [byte[]]$data) { return $hdr, $data }

$ms = New-Object System.IO.MemoryStream
$p = 0; $patched = 0; $count = 0
while ($p -lt $cb.Length - 110) {
    if ($s.Substring($p,6) -ne "070701") { $p++; continue }
    $fs = [Convert]::ToInt32($s.Substring($p+54,8),16)
    $ns = [Convert]::ToInt32($s.Substring($p+94,8),16)
    $name = $s.Substring($p+110,$ns-1)
    $ds = $p + 110 + $ns; $ds += (4 - ($ds % 4)) % 4
    $data = New-Object byte[] $fs
    if ($fs -gt 0) { [Array]::Copy($cb, $ds, $data, 0, $fs) }

    if ($name -ne "TRAILER!!!" -and $fs -gt 0 -and $fs -lt 200000) {
        $txt = [System.Text.Encoding]::GetEncoding(28591).GetString($data)
        if ($txt.Contains($oldLine)) {
            $new = $txt.Replace($oldLine, $newLine)
            $data = [System.Text.Encoding]::GetEncoding(28591).GetBytes($new)
            $patched++
            Say ("  patched {0} ({1} -> {2} bytes)" -f $name, $fs, $data.Length)
        }
    }

    # rebuild header with the new size and a fresh inode
    $ino = 500000 + $count
    $hdr = "070701" + ("{0:x8}" -f $ino) + $s.Substring($p+14, 8*11) + ("{0:x8}" -f $data.Length) + $s.Substring($p+62, 32) + ("{0:x8}" -f $ns) + $s.Substring($p+102, 8)
    $hb = [System.Text.Encoding]::ASCII.GetBytes($hdr)
    $ms.Write($hb,0,$hb.Length)
    $nb = [System.Text.Encoding]::ASCII.GetBytes($name); $ms.Write($nb,0,$nb.Length); $ms.WriteByte(0)
    $pad = (4 - (($hb.Length + $ns) % 4)) % 4
    for ($q=0; $q -lt $pad; $q++) { $ms.WriteByte(0) }
    if ($data.Length) { $ms.Write($data,0,$data.Length) }
    $pad2 = (4 - ($data.Length % 4)) % 4
    for ($q=0; $q -lt $pad2; $q++) { $ms.WriteByte(0) }
    $count++
    $p = $ds + $fs; $p += (4 - ($p % 4)) % 4
}
Say ("entries: {0}  patched: {1}" -f $count, $patched)
if ($patched -eq 0) { throw "no init files contained the devtmpfs line" }
$newCpio = $ms.ToArray()
Say ("new cpio: {0:N0} bytes" -f $newCpio.Length)

$cpioF = Join-Path $env:TEMP "patched.cpio"
$lzF   = Join-Path $env:TEMP "patched.lz4"
[System.IO.File]::WriteAllBytes($cpioF, $newCpio)
if (Test-Path $lzF) { Remove-Item $lzF -Force }
if ((Invoke-Lz4 @("-l","-9","-f",$cpioF,$lzF)) -ne 0) { throw "compress failed" }
$packed = [System.IO.File]::ReadAllBytes($lzF)
Say ("compressed: {0:N0} bytes  magic {1:x2} {2:x2}" -f $packed.Length, $packed[0], $packed[1])

$partSize = $src.Length
$outBytes = New-Object byte[] $partSize
$hdrPage = New-Object byte[] 4096
[Array]::Copy($src, 0, $hdrPage, 0, 4096)
[Array]::Copy([BitConverter]::GetBytes([uint32]$packed.Length), 0, $hdrPage, 12, 4)
[Array]::Copy($hdrPage, 0, $outBytes, 0, 4096)
[Array]::Copy($packed, 0, $outBytes, 4096, $packed.Length)
[Array]::Copy($src, $partSize - 64, $outBytes, $partSize - 64, 64)   # keep AVB footer
[System.IO.File]::WriteAllBytes($Out, $outBytes)
Say ""
Say ("wrote {0}  ramdisk_size {1:N0}" -f $Out, $packed.Length)

$vendor = 30826075
Say ("budget: vendor {0:N0} + init {1:N0} = {2:N0} / 67108864" -f $vendor, $packed.Length, ($vendor + $packed.Length))
