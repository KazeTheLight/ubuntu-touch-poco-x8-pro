# mk-diag-initboot.ps1 - build a *diagnostic* init_boot for klee.
#
# Why: the Halium initramfs on this port has no kernel modules at all
# (lib/modules/touch-arm64 is empty), so the panic handler cannot bring up its
# USB RNDIS/NCM gadget (usb_f_rndis / usb_f_ncm are modules). Every boot failure
# therefore looks like "black screen + reset loop -> BROM" with no log anywhere.
#
# This script appends one extra cpio archive to the stock UT ramdisk:
#   scripts/local-premount/klee-diag  - every 3 s writes a dmesg/mounts/partlabel
#                                       snapshot to the unused `oops` partition
#                                       (16 MiB, only holds MTK crash records)
#   scripts/panic/kmsgdump            - on panic, dumps the tail of dmesg there
#   .../ORDER files                   - run the above before telnet/resume
#
# After the failed boot, dump the oops partition from Android and read the last
# snapshot. Nothing else is changed: kernel, scripts and files stay identical.
#
#   .\mk-diag-initboot.ps1
#
# Output: images\ut_init_boot_diag.img   (same size, same header, same AVB tail)

[CmdletBinding()]
param(
    [string]$Source = "",
    [string]$Out    = ""
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$IMG  = Join-Path $HERE "images"
if (-not $Source) { $Source = Join-Path $IMG "ut_init_boot.img" }
if (-not $Out)    { $Out    = Join-Path $IMG "ut_init_boot_diag.img" }
$BASE_CPIO = Join-Path $HERE "ut_ramdisk.cpio"

function Say($m) { Write-Host $m }

# ---------------------------------------------------------------- newc writer
function New-CpioEntry {
    param(
        [string]$Name,
        [int]$Mode,
        [byte[]]$Data
    )
    $ms = New-Object System.IO.MemoryStream
    $namesize = $Name.Length + 1
    $hdr = "070701" +
           ("{0:x8}" -f $script:ino) +          # inode
           ("{0:x8}" -f $Mode) +                # mode
           ("{0:x8}" -f 0) +                    # uid
           ("{0:x8}" -f 0) +                    # gid
           ("{0:x8}" -f 1) +                    # nlink
           ("{0:x8}" -f 0) +                    # mtime
           ("{0:x8}" -f $Data.Length) +         # filesize
           ("{0:x8}" -f 0) +                    # devmajor
           ("{0:x8}" -f 0) +                    # devminor
           ("{0:x8}" -f 0) +                    # rdevmajor
           ("{0:x8}" -f 0) +                    # rdevminor
           ("{0:x8}" -f $namesize) +            # namesize
           ("{0:x8}" -f 0)                      # check
    $hb = [System.Text.Encoding]::ASCII.GetBytes($hdr)
    $ms.Write($hb, 0, $hb.Length)
    $nb = [System.Text.Encoding]::ASCII.GetBytes($Name)
    $ms.Write($nb, 0, $nb.Length)
    $ms.WriteByte(0)
    $pad = (4 - (($hb.Length + $namesize) % 4)) % 4
    for ($i = 0; $i -lt $pad; $i++) { $ms.WriteByte(0) }
    $ms.Write($Data, 0, $Data.Length)
    $pad2 = (4 - ($Data.Length % 4)) % 4
    for ($i = 0; $i -lt $pad2; $i++) { $ms.WriteByte(0) }
    $script:ino++
    return $ms.ToArray()
}

function New-CpioArchive {
    param([array]$Entries)   # array of @{Name=..;Mode=..;Text=..}
    $script:ino = 700
    $ms = New-Object System.IO.MemoryStream
    foreach ($e in $Entries) {
        $data = [System.Text.Encoding]::UTF8.GetBytes($e.Text)
        $b = New-CpioEntry -Name $e.Name -Mode $e.Mode -Data $data
        $ms.Write($b, 0, $b.Length)
    }
    # trailer
    $t = New-CpioEntry -Name "TRAILER!!!" -Mode 0 -Data ([byte[]]@())
    $ms.Write($t, 0, $t.Length)
    return $ms.ToArray()
}

# ------------------------------------------------------------------- payloads
$diag = @'
#!/bin/sh
# klee diagnostic snapshotter.
#
# v2 changes (v1 never showed up):
#  * v1 wrote to `oops`, which MTK AEE cycles through in 8 x 2 MiB slots on
#    every boot - the very next boot overwrote offset 0.  Now the log goes to
#    `expdb` (128 MiB MTK exception dump, never written on a normal boot) at
#    offset 1 MiB, with `oops` kept as a secondary target.
#  * device lookup also tries /dev/block/platform/*/by-name and creates /tmp.
#  * the write status of the previous round is logged, so a silent dd failure
#    is visible instead of invisible.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in
    prereqs) prereqs; exit 0 ;;
esac

find_part() {
    for d in /dev/disk/by-partlabel/$1 /dev/block/by-name/$1 \
             /dev/block/platform/*/by-name/$1 /dev/block/platform/*/*/by-name/$1; do
        [ -b "$d" ] && { echo "$d"; return 0; }
    done
    for u in /sys/class/block/*/uevent; do
        if grep -q "^PARTNAME=$1$" "$u" 2>/dev/null; then
            b=$(basename $(dirname "$u"))
            for d in "/dev/$b" "/dev/block/$b"; do
                [ -b "$d" ] && { echo "$d"; return 0; }
            done
        fi
    done
    return 1
}

(
    mkdir -p /tmp 2>/dev/null
    [ -d /sys/class/block ] || mount -t sysfs sysfs /sys 2>/dev/null
    [ -d /proc/1 ] || mount -t proc proc /proc 2>/dev/null
    WSTAT=""
    i=0
    while [ $i -lt 900 ]; do
        {
            echo "=== KLEEDIAG v2 seq=$i uptime=$(cat /proc/uptime 2>/dev/null) ==="
            echo "--- cmdline ---"
            cat /proc/cmdline 2>/dev/null
            echo "--- partitions ---"
            cat /proc/partitions 2>/dev/null
            echo "--- by-partlabel ---"
            ls /dev/disk/by-partlabel 2>/dev/null | tr '\n' ' '
            echo
            echo "--- dev-block ---"
            ls /dev/block 2>/dev/null | tr '\n' ' '
            echo
            echo "--- mapper ---"
            ls /dev/mapper 2>/dev/null
            echo "--- mounts ---"
            cat /proc/mounts 2>/dev/null
            echo "--- prev-write ---"
            echo "$WSTAT"
            echo "--- dmesg ---"
            dmesg 2>/dev/null | tail -n 400
            echo "=== KLEEDIAG END v2 ==="
        } > /tmp/klee-diag.txt 2>&1

        WSTAT=""
        for t in expdb oops; do
            dev=$(find_part $t) || continue
            if [ "$t" = "expdb" ]; then
                dd if=/tmp/klee-diag.txt of="$dev" bs=4096 seek=256 conv=notrunc 2>/dev/null
            else
                dd if=/tmp/klee-diag.txt of="$dev" bs=4096 conv=notrunc 2>/dev/null
            fi
            rc=$?
            WSTAT="$WSTAT $t=$dev:rc$rc:$(wc -c < /tmp/klee-diag.txt 2>/dev/null)b"
        done
        sync
        sleep 2
        i=$((i+1))
    done
) &
exit 0
'@

$panicdump = @'
#!/bin/sh
# klee: on panic, dump the tail of the kernel log into expdb (offset 1 MiB) and
# oops, so the reason is readable after booting Android again.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in
    prereqs) prereqs; exit 0 ;;
esac

find_part() {
    for d in /dev/disk/by-partlabel/$1 /dev/block/by-name/$1 \
             /dev/block/platform/*/by-name/$1 /dev/block/platform/*/*/by-name/$1; do
        [ -b "$d" ] && { echo "$d"; return 0; }
    done
    for u in /sys/class/block/*/uevent; do
        if grep -q "^PARTNAME=$1$" "$u" 2>/dev/null; then
            b=$(basename $(dirname "$u"))
            for d in "/dev/$b" "/dev/block/$b"; do
                [ -b "$d" ] && { echo "$d"; return 0; }
            done
        fi
    done
    return 1
}

mkdir -p /tmp 2>/dev/null
{
    echo "=== KLEEPANIC v2 reason=[$*] uptime=$(cat /proc/uptime 2>/dev/null) ==="
    echo "--- cmdline ---"
    cat /proc/cmdline 2>/dev/null
    echo "--- by-partlabel ---"
    ls /dev/disk/by-partlabel 2>/dev/null | tr '\n' ' '
    echo
    echo "--- mapper ---"
    ls /dev/mapper 2>/dev/null
    echo "--- mounts ---"
    cat /proc/mounts 2>/dev/null
    echo "--- dmesg ---"
    dmesg 2>/dev/null | tail -n 3000
    echo "=== KLEEPANIC END v2 ==="
} > /tmp/klee-panic.txt 2>&1

for t in expdb oops; do
    dev=$(find_part $t) || continue
    if [ "$t" = "expdb" ]; then
        dd if=/tmp/klee-panic.txt of="$dev" bs=4096 seek=256 conv=notrunc 2>/dev/null
    else
        dd if=/tmp/klee-panic.txt of="$dev" bs=4096 conv=notrunc 2>/dev/null
    fi
done
sync
exit 0
'@

$orderPre = @'
/scripts/local-premount/klee-diag "$@"
/scripts/local-premount/resume "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
'@

$orderPanic = @'
/scripts/panic/kmsgdump "$@"
/scripts/panic/telnet "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
'@

# ------------------------------------------------------------------- build
Say "source : $Source"
if (-not (Test-Path $BASE_CPIO)) {
    throw "missing $BASE_CPIO (extract it first: lz4 -d ramdisk.lz4 ut_ramdisk.cpio)"
}

$fs = [System.IO.File]::OpenRead($Source)
$hdr = New-Object byte[] 4096
$null = $fs.Read($hdr, 0, 4096)
$fs.Dispose()
$magic = [System.Text.Encoding]::ASCII.GetString($hdr, 0, 8)
$rs = [System.BitConverter]::ToUInt32($hdr, 12)
if ($magic -ne "ANDROID!") { throw "not an Android boot image" }
Say "source ramdisk: $rs bytes, header v$([System.BitConverter]::ToUInt32($hdr,40))"

$patch = New-CpioArchive -Entries @(
    @{ Name = "scripts/local-premount/klee-diag"; Mode = 0x81ed; Text = $diag },      # 0100755
    @{ Name = "scripts/local-premount/ORDER";     Mode = 0x81a4; Text = $orderPre },   # 0100644
    @{ Name = "scripts/panic/kmsgdump";           Mode = 0x81ed; Text = $panicdump },
    @{ Name = "scripts/panic/ORDER";              Mode = 0x81a4; Text = $orderPanic }
)
Say "patch archive : $($patch.Length) bytes"

# The stock image is TWO concatenated legacy-LZ4 streams: the generic Halium
# ramdisk plus the klee overlay (make-bootimage.sh appends them). Mirror that
# exactly: the patch becomes its own third stream, so it is parsed even if the
# kernel only honours the first archive of each stream.
$patchCpioPath = Join-Path $HERE "diag_patch.cpio"
[System.IO.File]::WriteAllBytes($patchCpioPath, $patch)
Say "patch cpio    : $($patch.Length) bytes"

$lz4 = "C:\Users\Kaze\AppData\Local\Temp\opencode\lz4\lz4.exe"
if (-not (Test-Path $lz4)) { throw "lz4.exe not found at $lz4" }
# lz4 writes progress to stderr; with $ErrorActionPreference=Stop that becomes a
# terminating NativeCommandError, so run it muted and check the exit code.
function Invoke-Lz4([string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try { $null = & $lz4 @argv 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    return $code
}
$patchLz4Path = Join-Path $HERE "diag_patch.cpio.lz4"
if (Test-Path $patchLz4Path) { Remove-Item $patchLz4Path -Force }
if ((Invoke-Lz4 @("-l", "-9", "-f", $patchCpioPath, $patchLz4Path)) -ne 0) { throw "lz4 compression failed" }
if (-not (Test-Path $patchLz4Path)) { throw "lz4 produced no output" }
$patchLz4 = [System.IO.File]::ReadAllBytes($patchLz4Path)

# original ramdisk bytes straight from the source image
$srcBytes = [System.IO.File]::ReadAllBytes($Source)
$origRamdisk = New-Object byte[] $rs
[Array]::Copy($srcBytes, 4096, $origRamdisk, 0, $rs)

$ramdisk = New-Object byte[] ($origRamdisk.Length + $patchLz4.Length)
[Array]::Copy($origRamdisk, 0, $ramdisk, 0, $origRamdisk.Length)
[Array]::Copy($patchLz4, 0, $ramdisk, $origRamdisk.Length, $patchLz4.Length)
Say "compressed    : $($ramdisk.Length) bytes (was $rs, +$($patchLz4.Length) patch stream)"

$partSize = (Get-Item $Source).Length
$tailLen  = 64
if (4096 + $ramdisk.Length -gt $partSize - $tailLen) { throw "ramdisk too large for the partition" }

$outBytes = New-Object byte[] $partSize
[System.IO.File]::WriteAllBytes($Out, $outBytes)   # zero file

$outHdr = [byte[]]$hdr.Clone()
[Array]::Copy([System.BitConverter]::GetBytes([uint32]$ramdisk.Length), 0, $outHdr, 12, 4)
# zero the padding area of the header (keep header_size / header_version)
[System.IO.File]::WriteAllBytes($Out, $outBytes)
$fs = [System.IO.File]::Open($Out, 'Open', 'ReadWrite')
$fs.Write($outHdr, 0, 4096)
$fs.Write($ramdisk, 0, $ramdisk.Length)
# keep the original AVB footer bytes at the very end (structure stays valid,
# hash is stale - the bootloader on this device is permissive / unlocked)
$fs.Seek($partSize - $tailLen, 'Begin')
$orig = [System.IO.File]::ReadAllBytes($Source)
$fs.Write($orig, $partSize - $tailLen, $tailLen)
$fs.Close()

$check = [System.IO.File]::ReadAllBytes($Out)
Say ""
Say "wrote: $Out"
Say ("  size        : {0}" -f $check.Length)
Say ("  magic       : {0}" -f [System.Text.Encoding]::ASCII.GetString($check,0,8))
Say ("  ramdisk_size: {0}" -f [System.BitConverter]::ToUInt32($check,12))
Say ("  ramdisk hdr : {0}" -f (([System.BitConverter]::ToString($check[4096..4099]))))
Say ("  tail64      : {0}" -f [System.Text.Encoding]::ASCII.GetString($check, ($check.Length-64), 4))
