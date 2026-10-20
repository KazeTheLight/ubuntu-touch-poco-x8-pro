# Switch the phone back to Android: restore the boot + init_boot backups that
# install-windows.ps1 took. Use with the phone in bootloader fastboot mode
# (Volume Down + Power), or from Android.

[CmdletBinding()]
param(
    [string]$Backup   = "",
    [string]$Adb      = "",
    [string]$Fastboot = "",
    [string]$Serials  = ""
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path

function Die ($m) { Write-Host "XX  $m" -ForegroundColor Red; exit 1 }

function Resolve-Tool([string]$name, [string]$explicit) {
    if ($explicit) { if (Test-Path $explicit) { return (Resolve-Path $explicit).Path }; Die "not found: $explicit" }
    foreach ($c in @((Join-Path $HERE "$name.exe"),
                     (Join-Path (Split-Path -Parent $HERE) "platform-tools\$name.exe"),
                     (Join-Path $env:USERPROFILE "platform-tools\$name.exe"))) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Die "$name not found"
}

$ADB      = Resolve-Tool "adb"      $Adb
$FASTBOOT = Resolve-Tool "fastboot" $Fastboot
if ($Serials) { $env:ANDROID_SERIAL = $Serials }

if (-not $Backup) { $Backup = Join-Path $HERE "backup-latest" }
if (-not (Test-Path $Backup)) { Die "no backup in $Backup" }

$bootFile = Join-Path $Backup "boot.img"
$initFile = Join-Path $Backup "init_boot.img"
foreach ($f in @($bootFile, $initFile)) { if (-not (Test-Path $f)) { Die "no $f in $Backup" } }

# if Android/UT is running and reachable over adb, go to the bootloader
$state = & $ADB get-state 2>&1
if (($state -join "") -match "device") { & $ADB reboot bootloader | Out-Null }

Write-Host "waiting for fastboot..."
$deadline = (Get-Date).AddMinutes(3)
$ready = $false
while ((Get-Date) -lt $deadline) {
    $d = & $FASTBOOT devices 2>&1
    if (($d -join "`n") -match "fastboot") { $ready = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) { Die "phone did not reach fastboot" }

$slot = "_a"
$cur = & $FASTBOOT getvar current-slot 2>&1
foreach ($line in ($cur -split "`r?`n")) {
    if ($line -match "current-slot:\s*(\S+)") {
        $slot = "_" + ($Matches[1] -replace "^_", "")
        break
    }
}
Write-Host "active slot: $slot"

& $FASTBOOT flash "boot$slot"      $bootFile
if ($LASTEXITCODE -ne 0) { Die "fastboot flash boot failed" }
& $FASTBOOT flash "init_boot$slot" $initFile
if ($LASTEXITCODE -ne 0) { Die "fastboot flash init_boot failed" }

& $FASTBOOT reboot | Out-Null
Write-Host "Booting Android." -ForegroundColor Green
