# fix-boot-header.ps1 - repair the Android boot image v4 header of ut_boot.img.
#
# Symptom (observed in expdb): LK logs
#   load_bootinfo_from_hdr:79: invalid boot image header
# and then jumps to a kernel that dies before printing anything.
#
# Cause: every u32 after kernel_size is shifted by 4 bytes:
#     offset 12 (ramdisk_size) holds header_size (0x630)
#     offset 16 (os_version)   holds the real ramdisk_size
#     offset 20 (header_size)  holds cmdline garbage
# The correct v3/v4 layout is
#     0 magic, 8 kernel_size, 12 ramdisk_size, 16 os_version, 20 header_size,
#     24..39 reserved, 40 header_version, 44 cmdline[1536], 1580 sig_size.
#
# boot.img on an init_boot device carries the kernel only: ramdisk_size = 0.
#
#   .\fix-boot-header.ps1
#
# Output: images\ut_boot_fixed.img

[CmdletBinding()]
param(
    [string]$Source = "",
    [string]$Out    = ""
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $HERE "images\ut_boot.img" }
if (-not $Out)    { $Out    = Join-Path $HERE "images\ut_boot_fixed.img" }

function Say($m) { Write-Host $m }

$b = [System.IO.File]::ReadAllBytes($Source)
function U32 { param($o) [BitConverter]::ToUInt32($b, $o) }

Say "source: $Source ($($b.Length) bytes)"
if ([System.Text.Encoding]::ASCII.GetString($b,0,8) -ne "ANDROID!") { throw "not an Android boot image" }

$hv = U32 40
Say ("header_version = {0}" -f $hv)
if ($hv -ne 4) { throw "expected header_version 4, got $hv" }

Say ""
Say "BEFORE (misaligned):"
Say ("  [8]  kernel_size  = {0}" -f (U32 8))
Say ("  [12] ramdisk_size = {0}" -f (U32 12))
Say ("  [16] os_version   = 0x{0:x8}" -f (U32 16))
Say ("  [20] header_size  = {0}" -f (U32 20))
Say ("  [40] header_ver   = {0}" -f (U32 40))
$cmdBefore = [System.Text.Encoding]::ASCII.GetString($b, 44, 64).TrimEnd([char]0)
Say ("  [44] cmdline      = '{0}'" -f $cmdBefore)

# ---------------------------------------------------------------- repair
$out = [byte[]]$b.Clone()
function SetU32 { param($o, $v)
    $bytes = [BitConverter]::GetBytes([uint32]$v)
    [Array]::Copy($bytes, 0, $script:out, $o, 4)
}

$kernelSize = U32 8
$cmdline    = $b[44..(44+1536-1)]          # already at the correct place
$hdrVer     = U32 40

# ramdisk_size: boot.img has no ramdisk when init_boot is a separate partition
SetU32 12 0
# os_version: stock klee boot.img leaves this zero; the bootloader does not
# need it and a bogus value risks rollback checks downstream
SetU32 16 0
# header_size: 1584 for v4 (1580 for v3)
SetU32 20 1584
# reserved 24..39
SetU32 24 0; SetU32 28 0; SetU32 32 0; SetU32 36 0
# header_version stays where it is
SetU32 40 $hdrVer
# cmdline back at 44 (unchanged, rewritten for clarity)
[Array]::Copy($cmdline, 0, $out, 44, $cmdline.Length)
# v4 signature_size at 1580
SetU32 1580 0

[System.IO.File]::WriteAllBytes($Out, $out)

# ---------------------------------------------------------------- verify
$c = [System.IO.File]::ReadAllBytes($Out)
function C32 { param($o) [BitConverter]::ToUInt32($c, $o) }
Say ""
Say "AFTER (fixed):"
Say ("  [8]  kernel_size  = {0}" -f (C32 8))
Say ("  [12] ramdisk_size = {0}" -f (C32 12))
Say ("  [16] os_version   = 0x{0:x8}" -f (C32 16))
Say ("  [20] header_size  = {0}" -f (C32 20))
Say ("  [24..39] reserved = {0} {1} {2} {3}" -f (C32 24),(C32 28),(C32 32),(C32 36))
Say ("  [40] header_ver   = {0}" -f (C32 40))
Say ("  [44] cmdline      = '{0}'" -f ([System.Text.Encoding]::ASCII.GetString($c, 44, 64).TrimEnd([char]0)))
Say ("  [1580] sig_size   = {0}" -f (C32 1580))
Say ("  footer            = '{0}'" -f ([System.Text.Encoding]::ASCII.GetString($c, $c.Length-64, 4)))

Say ""
Say "=== comparison with stock boot.img ==="
$fw = Join-Path $env:USERPROFILE "Documents\Poco_X8_Pro_Things\klee_id_global_images_OS3.0.304.0.WPJIDXM_16.0\images\boot.img"
if (Test-Path $fw) {
    $s = [System.IO.File]::ReadAllBytes($fw)
    function S32 { param($o) [BitConverter]::ToUInt32($s, $o) }
    Say ("  {0,-16} {1,16} {2,16} {3,16}" -f "field","stock","ut(fixed)","ut(old)")
    Say ("  {0,-16} {1,16} {2,16} {3,16}" -f "kernel_size", (S32 8), (C32 8), (U32 8))
    Say ("  {0,-16} {1,16} {2,16} {3,16}" -f "ramdisk_size", (S32 12), (C32 12), (U32 12))
    Say ("  {0,-16} {1,16} {2,16} {3,16}" -f "os_version", (S32 16), (C32 16), (U32 16))
    Say ("  {0,-16} {1,16} {2,16} {3,16}" -f "header_size", (S32 20), (C32 20), (U32 20))
    Say ("  {0,-16} {1,16} {2,16} {3,16}" -f "header_version", (S32 40), (C32 40), (U32 40))
} else {
    Say "  (stock boot.img not found, skipping comparison)"
}
Say ""
Say "wrote: $Out"
