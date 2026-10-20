# Switch the phone to Ubuntu Touch: flash the UT boot + init_boot to the active
# slot. Android's /data is not touched; boot-android.ps1 switches back.
#
# Works from Android (over adb) or with the phone already in bootloader fastboot.

[CmdletBinding()]
param(
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

$boot = Join-Path $HERE "images\ut_boot.img"
$init = Join-Path $HERE "images\ut_init_boot.img"
foreach ($f in @($boot, $init)) { if (-not (Test-Path $f)) { Die "missing $f" } }

# if Android is up, reboot it to the bootloader
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

# trust the live slot over the backup's record
$slot = "_a"
$cur = & $FASTBOOT getvar current-slot 2>&1
foreach ($line in ($cur -split "`r?`n")) {
    if ($line -match "current-slot:\s*(\S+)") {
        $slot = "_" + ($Matches[1] -replace "^_", "")
        break
    }
}
Write-Host "active slot: $slot"

& $FASTBOOT flash "boot$slot"      $boot
if ($LASTEXITCODE -ne 0) { Die "fastboot flash boot failed" }
& $FASTBOOT flash "init_boot$slot" $init
if ($LASTEXITCODE -ne 0) { Die "fastboot flash init_boot failed" }

& $FASTBOOT reboot | Out-Null
Write-Host "Booting Ubuntu Touch. The first boot can take a few minutes." -ForegroundColor Green
