# boot-ut-now.ps1 - one-shot full Ubuntu Touch boot test on klee.
#
# Background: LK stops the boot with
#     boot_linux_from_storage:928: ramdisk_map_sz cannot overrun mb_ramdisk.size
# because vendor_ramdisk_size + init_boot ramdisk exceeds 64 MiB. The OFox
# vendor_boot on the device makes that 68 MiB; the stock one plus the trimmed
# initramfs comes to 66.2 MiB, which fits.
#
# This flashes, on the ACTIVE slot:
#   boot_a         <- images\ut_boot.img            (UT kernel + UT ramdisk)
#   init_boot_a    <- images\ut_init_boot_lean.img  (initramfs without libcrypto)
#   vendor_boot_a  <- firmware\vendor_boot.img      (stock Xiaomi, not OFox)
#   vbmeta_a       <- firmware\vendor_boot.img dir\vbmeta.img (authentic 12 KiB)
#
# Restore with .\boot-android.ps1 (it puts back boot, init_boot, vbmeta AND
# vendor_boot from backup-latest = the current OFox setup).
#
#   .\boot-ut-now.ps1 [-WatchSeconds 300]

[CmdletBinding()]
param(
    [string]$Adb       = "",
    [string]$Fastboot  = "",
    [int]$WatchSeconds = 300,
    [string]$InitBoot  = ""
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$FW   = Join-Path $env:USERPROFILE "Documents\Poco_X8_Pro_Things\klee_id_global_images_OS3.0.304.0.WPJIDXM_16.0\images"
if (-not (Test-Path $FW)) {
    # fall back to any images dir under Poco_X8_Pro_Things that has a vendor_boot
    $FW = Get-ChildItem (Join-Path $env:USERPROFILE "Documents\Poco_X8_Pro_Things") -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
          ForEach-Object { Join-Path $_.FullName "images" } |
          Where-Object { Test-Path (Join-Path $_ "vendor_boot.img") } |
          Select-Object -First 1
}
if (-not $FW -or -not (Test-Path $FW)) { Die "stock firmware images not found" }
$FW = (Resolve-Path $FW).Path

$Log = Join-Path $HERE ("boot-ut-now-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
function Say([string]$m, [string]$c = "Gray") {
    $line = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m
    Write-Host $line -ForegroundColor $c
    Add-Content -Path $Log -Value $line
}
function Die($m) { Say "XX  $m" Red; exit 1 }

function Resolve-Tool([string]$name, [string]$explicit) {
    if ($explicit) { if (Test-Path $explicit) { return (Resolve-Path $explicit).Path }; Die "not found: $explicit" }
    foreach ($c in @((Join-Path $HERE "$name.exe"),
                     (Join-Path $HERE "platform-tools\$name.exe"),
                     (Join-Path (Split-Path -Parent $HERE) "platform-tools\$name.exe"),
                     "C:\Users\Kaze\Documents\Poco_X8_Pro_Things\platform-tools\$name.exe",
                     "C:\platform-tools\$name.exe")) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Die "$name not found"
}

function Tool-Out([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try { $out = & $exe @argv 2>&1 } finally { $ErrorActionPreference = $old }
    return (($out | ForEach-Object { "$_" }) -join "`n")
}
function Fb-Run([string[]]$argv) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try { $out = & $FASTBOOT @argv 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    $text = (($out | ForEach-Object { "$_" }) -join "`n")
    if ($text) { Say ("  fastboot> " + ($text -replace "`r?`n"," | ")) DarkGray }
    return $code
}

$ADB      = Resolve-Tool "adb"      $Adb
$FASTBOOT = Resolve-Tool "fastboot" $Fastboot
Say "=== boot-ut-now ===" Cyan
Say "log: $Log"

# ------------------------------------------------------------------- inputs
$bootImg  = Join-Path $HERE "images\ut_boot.img"
$initImg  = Join-Path $HERE "images\ut_init_boot_lean.img"
if ($InitBoot) { $initImg = (Resolve-Path $InitBoot).Path }
$vndImg   = Join-Path $FW   "vendor_boot.img"
$vbImg    = Join-Path $FW   "vbmeta.img"
foreach ($f in @($bootImg,$initImg,$vndImg,$vbImg)) {
    if (-not (Test-Path $f)) { Die "missing: $f" }
}

# sanity: the numbers LK will add up must stay below its 64 MiB limit
$vbBytes = [System.IO.File]::ReadAllBytes($vndImg)
$vrs     = [BitConverter]::ToUInt32($vbBytes, 24)
$ibBytes = [System.IO.File]::ReadAllBytes($initImg)
$irs     = [BitConverter]::ToUInt32($ibBytes, 12)
$limit   = 67108864
Say ("vendor_ramdisk = {0:N0}" -f $vrs)
Say ("init ramdisk   = {0:N0}" -f $irs)
Say ("sum            = {0:N0}  limit {1:N0}" -f ($vrs+$irs), $limit)
if (($vrs + $irs) -ge $limit) { Die "ramdisks still exceed mb_ramdisk - refusing to flash" }
Say ("headroom       = {0:N0} bytes" -f ($limit - ($vrs+$irs))) Green

# --------------------------------------------------------- reach bootloader
if ((Tool-Out $ADB @("get-state")) -match "device") {
    Say "Android is up -> reboot bootloader"
    & $ADB reboot bootloader | Out-Null
}
Say "waiting for fastboot..."
$deadline = (Get-Date).AddMinutes(3); $ready = $false
while ((Get-Date) -lt $deadline) {
    if ((Tool-Out $FASTBOOT @("devices")) -match "fastboot") { $ready = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) { Die "phone did not reach fastboot" }

$slot = "_a"
foreach ($line in ((Tool-Out $FASTBOOT @("getvar","current-slot")) -split "`r?`n")) {
    if ($line -match "current-slot:\s*(\S+)") { $slot = "_" + ($Matches[1] -replace "^_",""); break }
}
Say "active slot: $slot" Cyan

# ------------------------------------------------------------------- flash
$steps = @(
    @("boot$slot",        $bootImg),
    @("init_boot$slot",   $initImg),
    @("vendor_boot$slot", $vndImg),
    @("vbmeta$slot",      $vbImg)
)
foreach ($s in $steps) {
    Say ("flashing {0,-16} ({1})" -f $s[0], (Split-Path $s[1] -Leaf))
    if ((Fb-Run @("flash", $s[0], $s[1])) -ne 0) { Die "flash $($s[0]) failed" }
}
Fb-Run @("reboot") | Out-Null

# ------------------------------------------------------------------- watch
Say "--- watching $WatchSeconds s ---" Green
$seen = @{}
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt $WatchSeconds) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $now = @{}
    foreach ($d in (Get-PnpDevice -PresentOnly)) {
        $id = "$($d.InstanceId)"
        if ($id -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
            $now["VID_$($Matches[1]):PID_$($Matches[2])"] = "$($d.FriendlyName)"
        }
    }
    $ErrorActionPreference = $old
    foreach ($k in $now.Keys) { if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; Say ("  +USB {0}  {1}" -f $k, $now[$k]) Yellow } }
    foreach ($k in @($seen.Keys)) { if ($seen[$k] -eq 1 -and -not $now.ContainsKey($k)) { $seen[$k] = 0; Say ("  -USB {0}" -f $k) DarkGray } }
    if ((((Get-Date) - $t0).TotalSeconds % 5) -lt 1.2) {
        $a = Tool-Out $ADB @("devices")
        if ($a -match "device`$") { Say "  ADB IS UP!" Green; break }
    }
    Start-Sleep -Seconds 1
}
Say "--- watch finished ---"
Say ("seen: " + (($seen.Keys) -join ", "))
Say "If it failed: power-cycle (hold Power ~20 s), then run .\boot-android.ps1" Yellow
