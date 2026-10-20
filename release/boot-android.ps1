# Switch the phone back to Android: restore the boot + init_boot backups that
# install-windows.ps1 took. Use with the phone in bootloader fastboot mode
# (Volume Down + Power), or from Android.

[CmdletBinding()]
param(
    [string]$Backup   = "",
    [string]$Adb      = "",
    [string]$Fastboot = "",
    [string]$Serials  = "",
    # -Stock restores the pristine Xiaomi images from release\stock-firmware
    # instead of backup-latest (which holds the OFox vendor_boot that was on the
    # phone when the backups were taken).
    [switch]$Stock
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path

function Die ($m) { Write-Host "XX  $m" -ForegroundColor Red; exit 1 }

function Resolve-Tool([string]$name, [string]$explicit) {
    if ($explicit) { if (Test-Path $explicit) { return (Resolve-Path $explicit).Path }; Die "not found: $explicit" }
    foreach ($c in @((Join-Path $HERE "$name.exe"),
                     (Join-Path $HERE "platform-tools\$name.exe"),
                     (Join-Path (Split-Path -Parent $HERE) "platform-tools\$name.exe"),
                     (Join-Path $env:USERPROFILE "platform-tools\$name.exe"),
                     "C:\platform-tools\$name.exe")) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    # platform-tools often lives a few levels down under Documents, e.g.
    # Documents\Poco_X8_Pro_Things\platform-tools on this machine.
    foreach ($root in @((Join-Path $env:USERPROFILE "Documents"), $env:USERPROFILE)) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter "platform-tools" -Directory -Recurse -Depth 2 `
                    -ErrorAction SilentlyContinue |
                 ForEach-Object { Join-Path $_.FullName "$name.exe" } |
                 Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($found) { return (Resolve-Path $found).Path }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Die "$name not found"
}

# adb and fastboot write diagnostics to stderr, and $ErrorActionPreference=Stop
# turns a merged stderr line into a terminating error. Capture with errors muted
# and return plain text so the callers can match on it.
function Tool-Out([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try   { $out = & $exe @argv 2>&1 }
    finally { $ErrorActionPreference = $old }
    return (($out | ForEach-Object { "$_" }) -join "`n")
}

# fastboot prints its progress on stderr; if the script is piped through 2>&1,
# those lines become ErrorRecords and EAP=Stop kills the script mid-flash.
function Fb-Run([string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try   { $out = & $FASTBOOT @argv 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    $text = (($out | ForEach-Object { "$_" }) -join "`n")
    if ($text) { Write-Host $text }
    return $code
}

$ADB      = Resolve-Tool "adb"      $Adb
$FASTBOOT = Resolve-Tool "fastboot" $Fastboot
if ($Serials) { $env:ANDROID_SERIAL = $Serials }

if (-not $Backup) {
    if ($Stock) { $Backup = Join-Path $HERE "stock-firmware" }
    else        { $Backup = Join-Path $HERE "backup-latest" }
}
if (-not (Test-Path $Backup)) { Die "no backup in $Backup" }
Write-Host ("restoring from: {0}" -f $Backup) -ForegroundColor Cyan

$bootFile = Join-Path $Backup "boot.img"
$initFile = Join-Path $Backup "init_boot.img"
foreach ($f in @($bootFile, $initFile)) { if (-not (Test-Path $f)) { Die "no $f in $Backup" } }

# if Android/UT is running and reachable over adb, go to the bootloader
$state = Tool-Out $ADB @("get-state")
if ($state -match "device") { & $ADB reboot bootloader | Out-Null }

Write-Host "waiting for fastboot..."
$deadline = (Get-Date).AddMinutes(3)
$ready = $false
while ((Get-Date) -lt $deadline) {
    $d = Tool-Out $FASTBOOT @("devices")
    if ($d -match "fastboot") { $ready = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) { Die "phone did not reach fastboot" }

$slot = "_a"
$cur = Tool-Out $FASTBOOT @("getvar", "current-slot")
foreach ($line in ($cur -split "`r?`n")) {
    if ($line -match "current-slot:\s*(\S+)") {
        $slot = "_" + ($Matches[1] -replace "^_", "")
        break
    }
}
Write-Host "active slot: $slot"

Write-Host "flashing boot$slot ..."
if ((Fb-Run @("flash", "boot$slot", $bootFile)) -ne 0) { Die "fastboot flash boot failed" }
Write-Host "flashing init_boot$slot ..."
if ((Fb-Run @("flash", "init_boot$slot", $initFile)) -ne 0) { Die "fastboot flash init_boot failed" }

# diag-boot-ut.ps1 also disables vbmeta verification to get LK to load the UT
# images; put the stock vbmeta back as well, or Android would stay unverified.
$vbFile = Join-Path $Backup "vbmeta.img"
if (Test-Path $vbFile) {
    Write-Host "flashing vbmeta$slot ..."
    if ((Fb-Run @("flash", "vbmeta$slot", $vbFile)) -ne 0) { Die "fastboot flash vbmeta failed" }
}

# boot-ut-now.ps1 / diag-boot-ut.ps1 may replace vendor_boot with the stock
# Xiaomi one; without the OFox copy Android cannot hand off to the kernel on
# this port, so always restore it too.
$vbootFile = Join-Path $Backup "vendor_boot.img"
if (Test-Path $vbootFile) {
    Write-Host "flashing vendor_boot$slot ..."
    if ((Fb-Run @("flash", "vendor_boot$slot", $vbootFile)) -ne 0) { Die "fastboot flash vendor_boot failed" }
}

Fb-Run @("reboot") | Out-Null
Write-Host "Booting Android." -ForegroundColor Green
