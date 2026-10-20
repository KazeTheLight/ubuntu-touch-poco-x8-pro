# Ubuntu Touch dual boot installer for Poco X8 Pro (klee) - Windows edition.
#
# Android stays untouched. Ubuntu Touch lives in a new logical partition
# "ut_data" carved out of the free space in super; switching systems only swaps
# the boot + init_boot images of the active slot.
#
# Why this exists: the upstream release/install.sh needs mkfs.ext4, debugfs,
# e2fsck and img2simg, none of which exist on Windows. The GitHub Actions job
# "ut_data.img for the Windows installer" builds ut_data.img on Linux and hands
# it back as an artifact. This script then only needs adb + fastboot, which are
# already in platform-tools.
#
#   .\install-windows.ps1 -DryRun    backups + checks only, changes nothing
#   .\install-windows.ps1            full install
#
# Start with the phone booted into Android, USB debugging on, root granted to
# the "Shell" app (KernelSU / Magisk).

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Adb      = "",
    [string]$Fastboot = "",
    [string]$Serials  = "",
    [int]$UtDataMib   = 0
)

$ErrorActionPreference = "Stop"

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$IMG  = Join-Path $HERE "images"
$WORK = Join-Path $HERE "work"

function Say  ($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "XX  $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- tool lookup
# platform-tools is usually a sibling of this checkout, or on PATH. Accept both.
function Resolve-Tool([string]$name, [string]$explicit) {
    if ($explicit) {
        if (Test-Path $explicit) { return (Resolve-Path $explicit).Path }
        Die "not found: $explicit"
    }
    $candidates = @(
        (Join-Path $HERE "$name.exe"),
        (Join-Path $HERE "platform-tools\$name.exe"),
        (Join-Path (Split-Path -Parent $HERE) "platform-tools\$name.exe"),
        (Join-Path $env:USERPROFILE "platform-tools\$name.exe")
    )
    # a sibling folder named Poco_X8_Pro_Things\platform-tools is the common case
    foreach ($c in $candidates) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $flag = "-" + $name.Substring(0,1).ToUpper() + $name.Substring(1)
    Die "$name not found. Pass $flag <path> or put platform-tools on PATH."
}

$ADB      = Resolve-Tool "adb"      $Adb
$FASTBOOT = Resolve-Tool "fastboot" $Fastboot

# adb/fastboot must not be steered by a stray env var. Assigning $null leaves an
# empty string behind, which adb rejects, so remove the variable instead.
Remove-Item Env:\ANDROID_SERIAL -ErrorAction SilentlyContinue
if ($Serials) { $env:ANDROID_SERIAL = $Serials }

# NOTE: $args is a reserved automatic variable. Copying it to a named array and
# calling the native tool through it keeps quoting intact for paths with spaces.
function Invoke-Adb {
    $argv = @($args)
    & $ADB @argv
}

function Invoke-Fb {
    $argv = @($args)
    & $FASTBOOT @argv
}

function AdbSu([string]$cmd) {
    # root is needed for every dd against /dev/block/by-name/*
    $out = Invoke-Adb shell "su -c '$cmd'"
    return ($out -join "`n")
}

function Pull([string]$remote, [string]$local) {
    $out = Invoke-Adb pull $remote $local
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------- 1/6 checks
Say "1/6 Checking the phone (must be booted into Android with adb)"

$dev = (Invoke-Adb shell getprop ro.product.device) -join "" | ForEach-Object { $_.Trim() }
if ($dev -ne "klee") { Die "this is '$dev', not klee" }

$slot = ((Invoke-Adb shell getprop ro.boot.slot_suffix) -join "").Trim()
if ($slot -ne "_a" -and $slot -ne "_b") { Die "unknown slot '$slot'" }

$root = AdbSu "id"
if ($root -notmatch "uid=0") { Die "no root: grant root to the 'Shell' app (KernelSU / Magisk) and retry" }

Write-Host "device=$dev slot=$slot root=ok"

# ---------------------------------------------------------------- 2/6 backup
Say "2/6 Backing up the boot images of slot $slot (needed to return to Android)"

$STAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$BK = Join-Path $HERE "backup-$STAMP"
New-Item -ItemType Directory -Force -Path $BK | Out-Null

foreach ($p in @("boot","init_boot","vendor_boot","dtbo","vbmeta","vbmeta_system","vbmeta_vendor")) {
    $remote = "/data/local/tmp/$p.img"
    $local  = Join-Path $BK "$p.img"
    $ok = $false
    $dump = AdbSu "dd if=/dev/block/by-name/$p$slot of=$remote bs=1M 2>/dev/null"
    if ($LASTEXITCODE -eq 0) { $ok = Pull $remote $local }
    if ($ok -and (Test-Path $local) -and (Get-Item $local).Length -gt 0) {
        Write-Host ("  saved {0}{1} ({2} bytes)" -f $p, $slot, (Get-Item $local).Length)
    } else {
        if ($p -eq "boot" -or $p -eq "init_boot") { Die "could not back up $p$slot" }
        Warn "could not back up $p$slot (not needed for dual boot)"
    }
    AdbSu "rm -f $remote" | Out-Null
}

# the boot backup must be a real Android boot image
foreach ($f in @("boot","init_boot")) {
    $p = Join-Path $BK "$f.img"
    if (-not (Test-Path $p)) { Die "missing $p" }
    $magic = [System.Text.Encoding]::ASCII.GetString([byte[]](Get-Content $p -Encoding Byte -TotalCount 8))
    if ($magic -ne "ANDROID!") { Die "$f backup looks wrong (magic '$magic')" }
}

Set-Content -Path (Join-Path $BK "slot") -Value $slot -NoNewline
$latest = Join-Path $HERE "backup-latest"
if (Test-Path $latest) { Remove-Item $latest -Force }
# a directory junction keeps the same "backup-latest/boot.img" layout install.sh uses
New-Item -ItemType Junction -Path $latest -Target $BK | Out-Null

# ------------------------------------------------------------ 2b/6 IMEI data
Say "2b/6 Backing up IMEI / NVRAM partitions (keep this folder safe!)"

$IMEI = Join-Path $BK "imei"
New-Item -ItemType Directory -Force -Path $IMEI | Out-Null

foreach ($p in @("nvram","nvdata","nvcfg","protect1","protect2","md_sec","persist","proinfo")) {
    $remote = "/data/local/tmp/$p.img"
    $local  = Join-Path $IMEI "$p.img"
    $ok = $false
    $dump = AdbSu "dd if=/dev/block/by-name/$p of=$remote bs=1M 2>/dev/null"
    if ($LASTEXITCODE -eq 0) { $ok = Pull $remote $local }
    if ($ok -and (Test-Path $local) -and (Get-Item $local).Length -gt 0) {
        Write-Host ("  saved {0} ({1} bytes)" -f $p, (Get-Item $local).Length)
    } else {
        if ($p -in @("nvram","nvdata","protect1","protect2")) {
            Die "could not back up $p (IMEI data) - stopping for safety"
        }
        Warn "could not back up $p"
    }
    AdbSu "rm -f $remote" | Out-Null
}

$sums = Get-ChildItem $IMEI -Filter *.img | Get-FileHash -Algorithm SHA256 |
        ForEach-Object { "$($_.Hash.ToLower())  $(Split-Path -Leaf $_.Path)" }
Set-Content -Path (Join-Path $IMEI "SHA256SUMS") -Value ($sums -join "`n")

# ------------------------------------------------------------ 3/6 super space
Say "3/6 Checking free space in super"

$lpdump = AdbSu "lpdump --slot=$($slot.Substring(1))"
if ($lpdump -match "unknown option" -or $lpdump -notmatch "super:") {
    $lpdump = AdbSu "lpdump"
}
Set-Content -Path (Join-Path $BK "lpdump.txt") -Value $lpdump

$EXISTS = $false
if ($lpdump -match "Name: ut_data") {
    $EXISTS = $true
    Warn "ut_data already exists (re-install: it will be recreated, Ubuntu Touch data is lost)"
}

# "super: <start> .. <end>: <name> (<n> sectors)"
$usedSectors = 0
$oldUt = 0
foreach ($line in ($lpdump -split "`r?`n")) {
    if ($line -match '^\s*super:\s+.*\((\d+)\s+sectors\)') {
        $n = [int64]$Matches[1]
        $usedSectors += $n
        if ($line -match ':\s*ut_data\s') { $oldUt += $n }
    }
}

$superBytes = $null
foreach ($line in ($lpdump -split "`r?`n")) {
    if ($line -match '^\s*Size:\s+(\d+)\s+bytes') { $superBytes = [int64]$Matches[1]; break }
}
if (-not $superBytes) { Die "could not read the super size from lpdump" }

$freeMib = [math]::Floor(($superBytes - ($usedSectors - $oldUt) * 512) / 1048576) - 64
Write-Host ("super={0} MiB, free~{1} MiB" -f [math]::Floor($superBytes/1048576), $freeMib)

$UT_DATA_MIN_MIB = 2560
$UT_DATA_MAX_MIB = 6144
if ($freeMib -lt $UT_DATA_MIN_MIB) {
    Die "not enough free space in super ($freeMib MiB < $UT_DATA_MIN_MIB MiB)"
}

if ($UtDataMib -gt 0) {
    $UT_MIB = $UtDataMib
    Write-Host "ut_data size overridden to $UT_MIB MiB"
} else {
    $UT_MIB = $freeMib
    if ($UT_MIB -gt $UT_DATA_MAX_MIB) { $UT_MIB = $UT_DATA_MAX_MIB }
    Write-Host "ut_data will be $UT_MIB MiB"
}

# ------------------------------------------------------- 4/6 ut_data.img
# On Linux install.sh builds this with mkfs.ext4 + debugfs + img2simg. None of
# those exist on Windows, so the image is downloaded from the Actions artifact
# instead. If it is missing, stop with a clear instruction rather than build a
# broken partition.
Say "4/6 Locating ut_data.img (${UT_MIB} MiB)"

$UTIMG = Join-Path $IMG "ut_data.img"
if (-not (Test-Path $UTIMG)) {
    Die @"
missing $UTIMG

The ut_data image cannot be built on Windows (it needs mkfs.ext4, debugfs and
img2simg, which are Linux-only).

Download the "klee-utdata" artifact from the GitHub Actions run and unzip
ut_data.img into:
  $IMG

Then run this script again.
"@
}
Write-Host ("ut_data.img: {0} bytes" -f (Get-Item $UTIMG).Length)

# the image was built for a specific size; a mismatch means it would not fit
$imgMib = [math]::Floor((Get-Item $UTIMG).Length / 1MB)
Write-Host "ut_data.img is ~$imgMib MiB on disk (sparse); requested $UT_MIB MiB"
if ($freeMib -lt $UT_DATA_MIN_MIB) { Die "not enough room" }

if ($DryRun) {
    Say "Dry run finished: backups in $BK. Nothing was changed on the phone."
    exit 0
}

# ------------------------------------------------------- 5/6 push to phone
Say "5/6 Pushing the switch script and images to the phone (/sdcard/klee-ut)"

Invoke-Adb shell mkdir -p /sdcard/klee-ut | Out-Null
$toUbuntu = Join-Path $HERE "device\to-ubuntu.sh"
foreach ($f in @((Join-Path $IMG "ut_boot.img"),
                 (Join-Path $IMG "ut_init_boot.img"),
                 $toUbuntu)) {
    if (-not (Test-Path $f)) { Die "missing $f" }
}
$push = Invoke-Adb push (Join-Path $IMG "ut_boot.img") (Join-Path $IMG "ut_init_boot.img") $toUbuntu "/sdcard/klee-ut/"
if ($LASTEXITCODE -ne 0) { Die "adb push failed: $push" }

# ------------------------------------------------------- 6/6 create + flash
Say "6/6 Creating ut_data in super (fastbootd) and flashing it"

Invoke-Adb reboot fastboot | Out-Null
Write-Host "waiting for fastbootd..."
$deadline = (Get-Date).AddMinutes(3)
$ready = $false
while ((Get-Date) -lt $deadline) {
    $d = Invoke-Fb devices
    if (($d -join "`n") -match "fastboot") { $ready = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) { Die "phone did not enter fastbootd. Reboot to Android, then retry." }

$isUser = Invoke-Fb getvar is-userspace
if (($isUser -join "`n") -notmatch "yes") { Die "not in fastbootd (userspace fastboot)" }

$snap = Invoke-Fb getvar snapshot-update-status
if (($snap -join "`n") -notmatch "none") {
    Warn "an OTA snapshot may be pending; if creating the partition fails, boot Android once and retry"
}

if ($EXISTS) {
    Invoke-Fb delete-logical-partition ut_data | Out-Null
}
$sizeBytes = $UT_MIB * 1MB
$out = Invoke-Fb create-logical-partition ut_data $sizeBytes
if ($LASTEXITCODE -ne 0) { Die "create-logical-partition failed: $out" }

$out = Invoke-Fb flash ut_data $UTIMG
if ($LASTEXITCODE -ne 0) { Die "fastboot flash ut_data failed: $out" }
Invoke-Fb getvar partition-size:ut_data | Write-Host

Say "Done. Rebooting back into Android (still untouched)."
Invoke-Fb reboot | Out-Null

Write-Host @"

Next:
  * Boot Ubuntu Touch:   .\boot-ubuntu.ps1      (from Android over adb/fastboot)
                         or on the phone: su -c sh /sdcard/klee-ut/to-ubuntu.sh
  * Back to Android:     .\boot-android.ps1
  * Backups of your Android boot images: $BK

Keep $BK safe. You need it to return to Android.
"@
