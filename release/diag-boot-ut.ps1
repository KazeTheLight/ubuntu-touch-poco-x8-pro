# diag-boot-ut.ps1 - boot Ubuntu Touch and *watch* what the phone actually does.
#
# Why: a failed UT boot leaves no kernel log anywhere (pstore/ramoops gets
# overwritten by the next Android boot, the `oops` MTD record is written by
# Android, expdb is empty).  So instead of guessing, flash UT and observe the
# device live:
#   * USB device ids appear/disappear (0e8d:0003 = BROM, 0e8d:2000 = preloader,
#     18d1:d001 = Halium initrd panic shell, 2717:* = Android adb/fastboot)
#   * if the Halium initrd panic handler runs, it also starts a DHCP server and
#     busybox telnetd on 192.168.2.15:23 -> we connect and pull dmesg live
#   * Ubuntu Touch's own usbnet comes up on 10.15.19.82 (ssh 8022)
#
# Nothing is written to the phone except boot_a/init_boot_a (mode flash), which
# restore-android.ps1 puts back.
#
#   .\diag-boot-ut.ps1                 # flash UT boot images, watch 5 min
#   .\diag-boot-ut.ps1 -Mode boot      # try fastboot boot (no writes)
#   .\diag-boot-ut.ps1 -WatchSeconds 600

[CmdletBinding()]
param(
    [string]$Adb           = "",
    [string]$Fastboot      = "",
    [string]$Serials       = "",
    # flash    : real UT boot (boot_a + init_boot_a)
    # initboot : bisect - UT initramfs only, keep the working Android kernel
    # boot     : fastboot boot (this device's LK rejects it)
    [ValidateSet("flash", "initboot", "boot")][string]$Mode = "flash",
    [string]$InitBoot      = "",
    [int]$WatchSeconds     = 300,
    [string]$Log           = ""
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Log) { $Log = Join-Path $HERE ("diag-boot-ut-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss")) }

function Say([string]$msg, [string]$color = "Gray") {
    $line = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $Log -Value $line
}
function Die($m) { Say "XX  $m" Red; exit 1 }

function Resolve-Tool([string]$name, [string]$explicit) {
    if ($explicit) { if (Test-Path $explicit) { return (Resolve-Path $explicit).Path }; Die "not found: $explicit" }
    foreach ($c in @((Join-Path $HERE "$name.exe"),
                     (Join-Path $HERE "platform-tools\$name.exe"),
                     (Join-Path (Split-Path -Parent $HERE) "platform-tools\$name.exe"),
                     (Join-Path $env:USERPROFILE "platform-tools\$name.exe"),
                     "C:\platform-tools\$name.exe")) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
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

# adb/fastboot write diagnostics to stderr; with $ErrorActionPreference=Stop a
# merged stderr line becomes a terminating NativeCommandError. Mute and return text.
function Tool-Out([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try   { $out = & $exe @argv 2>&1 }
    finally { $ErrorActionPreference = $old }
    return (($out | ForEach-Object { "$_" }) -join "`n")
}

function Fb-Run([string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try   { $out = & $FASTBOOT @argv 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    $text = (($out | ForEach-Object { "$_" }) -join "`n")
    if ($text) { Say ("  fastboot> " + ($text -replace "`r?`n", " | ")) }
    return $code
}

# ---------------------------------------------------------------- usb inventory
function Get-UsbMap {
    $map = @{}
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        foreach ($d in (Get-PnpDevice -PresentOnly)) {
            $id = "$($d.InstanceId)"
            if ($id -notmatch '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { continue }
            $key = "VID_$($Matches[1]):PID_$($Matches[2])"
            $name = "$($d.FriendlyName)"
            if (-not $map.ContainsKey($key)) { $map[$key] = $name }
        }
    } finally { $ErrorActionPreference = $old }
    return $map
}

function Watch-Usb([hashtable]$known, [ref]$seen) {
    $now = Get-UsbMap
    foreach ($k in $now.Keys) {
        if (-not $known.ContainsKey($k)) {
            $known[$k] = $now[$k]
            $seen.Value += ,@($k, $now[$k])
            Say ("  +USB  {0}  {1}" -f $k, $now[$k]) "Yellow"
        }
    }
    foreach ($k in @($known.Keys)) {
        if (-not $now.ContainsKey($k)) {
            Say ("  -USB  {0}  {1}" -f $k, $known[$k]) "DarkGray"
            $known.Remove($k)
        }
    }
}

# ------------------------------------------------------------------ tcp probe
function Test-Tcp([string]$ip, [int]$port, [int]$timeoutMs = 800) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($ip, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

# Every write/read is guarded: busybox telnetd drops the link as soon as the
# panic handler reboots or the shell exits, and an uncaught IOException used to
# kill the whole watcher right when the capture started.
function Telnet-Capture([string]$ip, [int]$port, [string]$outFile, [int]$seconds = 45) {
    Say ("telnet: connecting to {0}:{1}" -f $ip, $port) Green
    $c = New-Object System.Net.Sockets.TcpClient
    $sb = New-Object System.Text.StringBuilder
    try {
        $c.Connect($ip, $port)
        $c.ReceiveTimeout = 2000
        $ns = $c.GetStream()
    } catch {
        Say ("telnet: connect failed: {0}" -f $_.Exception.Message) Red
        try { $c.Close() } catch { }
        return ""
    }
    # send one command, swallow connection loss
    $send = {
        param($text)
        if (-not $text) { return $false }
        try {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
            $ns.Write($bytes, 0, $bytes.Length)
            $ns.Flush()
            return $true
        } catch { return $false }
    }
    $deadline = (Get-Date).AddSeconds($seconds)
    # cmd, wait-before-next-send-ms (longer for commands with big output)
    $cmds = @(
        @("",            600),
        @("id`n",        900),
        @("uname -a`n",  900),
        @("cat /proc/cmdline`n", 1500),
        @("cat /proc/uptime`n",  900),
        @("cat /proc/mounts`n",  2000),
        @("ls /dev/disk/by-partlabel`n", 1500),
        @("ls /dev/mapper`n",    1500),
        @("dmesg | tail -n 200`n", 4000),
        @("cat /proc/device-tree/firmware/android/bootargs`n", 3000),
        @("exit`n",      400)
    )
    $buf = New-Object byte[] 16384
    $ci = 0
    $nextSend = Get-Date
    $alive = $true
    # asynchronous read: telnetd is silent whenever it has nothing to say, so a
    # DataAvailable poll loop misses everything that arrives between polls.
    $pending = $null
    $reads = 0
    $lastErr = ""
    $nextSend = Get-Date
    $alive = $true
    while ($alive -and (Get-Date) -lt $deadline) {
        try {
            if (-not $pending) {
                $pending = $ns.BeginRead($buf, 0, $buf.Length, $null, $null)
            }
            if ($pending.AsyncWaitHandle.WaitOne(150)) {
                $n = $ns.EndRead($pending)
                $pending = $null
                if ($n -le 0) { $alive = $false; break }
                $reads++
                $null = $sb.Append([System.Text.Encoding]::GetEncoding(28591).GetString($buf, 0, $n))
                # answer immediately instead of serving the timer only
                if ($ci -lt $cmds.Count -and $cmds[$ci][0]) {
                    $cmd = $cmds[$ci][0]
                    if (-not (& $send $cmd)) { $alive = $false; break }
                    Say ("telnet: > {0}" -f ($cmd.Trim())) DarkGray
                    $ci++
                    $nextSend = (Get-Date).AddMilliseconds($cmds[$ci-1][1])
                }
            } elseif ($ci -lt $cmds.Count -and (Get-Date) -ge $nextSend) {
                $cmd = $cmds[$ci][0]
                if ($cmd) {
                    if (-not (& $send $cmd)) { $alive = $false; break }
                    Say ("telnet: > {0}" -f ($cmd.Trim())) DarkGray
                }
                $ci++
                $nextSend = (Get-Date).AddMilliseconds($cmds[$ci-1][1])
            } elseif ($ci -ge $cmds.Count) {
                break
            }
        } catch { $lastErr = $_.Exception.InnerException.Message; $alive = $false; break }
    }
    Say ("telnet: loop end reads={0} pending={1} alive={2} err={3}" -f $reads, [bool]$pending, $alive, $lastErr) DarkGray
    try { $c.Close() } catch { }
    $text = $sb.ToString()
    # strip telnet negotiation bytes (IAC ...) so the log is readable
    $text = [regex]::Replace($text, "\xFF[\xFB-\xFE].", "")
    $text = [regex]::Replace($text, "\xFF\xF4", "")
    [System.IO.File]::WriteAllText($outFile, $text)
    Say ("telnet: saved {0} bytes -> {1}" -f $text.Length, $outFile) Green
    return $text
}

# ----------------------------------------------------------------------- main
Say "=== diag-boot-ut ===" Cyan
$ADB      = Resolve-Tool "adb"      $Adb
$FASTBOOT = Resolve-Tool "fastboot" $Fastboot
if ($Serials) { $env:ANDROID_SERIAL = $Serials }
Say "adb      : $ADB"
Say "fastboot : $FASTBOOT"
Say "log      : $Log"

$boot = Join-Path $HERE "images\ut_boot.img"
$init = Join-Path $HERE "images\ut_init_boot.img"
if ($InitBoot) { $init = $InitBoot }
$combo = Join-Path $HERE "images\ut_boot_fastboot-boot.img"
if ($Mode -eq "boot") { if (-not (Test-Path $combo)) { Die "missing $combo" } }
elseif ($Mode -eq "initboot") { if (-not (Test-Path $init)) { Die "missing $init" } }
else { foreach ($f in @($boot, $init)) { if (-not (Test-Path $f)) { Die "missing $f" } } }

$known = Get-UsbMap
Say ("usb devices before: " + (($known.Keys | Sort-Object) -join ", "))

# Android running? reboot it to the bootloader
$state = Tool-Out $ADB @("get-state")
if ($state -match "device") { Say "Android is up -> reboot bootloader"; & $ADB reboot bootloader | Out-Null }

Say "waiting for fastboot..." 
$deadline = (Get-Date).AddMinutes(3); $ready = $false
while ((Get-Date) -lt $deadline) {
    if ((Tool-Out $FASTBOOT @("devices")) -match "fastboot") { $ready = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) { Die "phone did not reach fastboot" }

$slot = "_a"
foreach ($line in ((Tool-Out $FASTBOOT @("getvar", "current-slot")) -split "`r?`n")) {
    if ($line -match "current-slot:\s*(\S+)") { $slot = "_" + ($Matches[1] -replace "^_", ""); break }
}
Say "active slot: $slot" Cyan

if ($Mode -eq "boot") {
    Say "fastboot boot $combo (nothing is written)" Cyan
    Fb-Run @("boot", $combo) | Out-Null
} elseif ($Mode -eq "initboot") {
    Say "BISECT: flashing ONLY init_boot$slot with the UT initramfs." Cyan
    Say "boot$slot keeps the stock Android kernel." Yellow
    if ((Fb-Run @("flash", "init_boot$slot", $init)) -ne 0) { Die "flash init_boot$slot failed" }
    Fb-Run @("reboot") | Out-Null
} else {
    # ---- IMPORTANT, learned from the expdb bootloader log:
    # LK reads vbmeta first and authenticates boot/init_boot through it. With
    # the stock vbmeta, flash() succeeds but LK never issues "Load 'boot_a'"
    # (14 LK sessions showed boot_a/init_boot_a were never loaded after a
    # flash). vbmeta_a is therefore rewritten with flags=2|4 (verification and
    # hashtree disabled), which makes LK skip authentication. The original is
    # kept in the backup dir and boot-android.ps1 puts it back.
    Say "flashing boot$slot ..." Cyan
    if ((Fb-Run @("flash", "boot$slot", $boot)) -ne 0) { Die "flash boot$slot failed" }
    Say "flashing init_boot$slot ..." Cyan
    if ((Fb-Run @("flash", "init_boot$slot", $init)) -ne 0) { Die "flash init_boot$slot failed" }
    $novb = Join-Path $HERE "images\android_vbmeta_disabled.img"
    if (Test-Path $novb) {
        Say "flashing vbmeta$slot (flags=disable-verity+disable-verification, backup kept) ..." Yellow
        if ((Fb-Run @("flash", "vbmeta$slot", $novb)) -ne 0) { Die "flash vbmeta$slot failed" }
    } else {
        Say "WARNING: $novb missing - boot will likely be rejected by LK" Red
    }
    Fb-Run @("reboot") | Out-Null
}

Say "--- watching for $WatchSeconds s (look at the phone screen!) ---" Green
$seen = @()
$t0 = Get-Date
$found = $false
$lastPing = [DateTime]::MinValue
$telnetDone = $false
$lastTelnet = [DateTime]::MinValue
while (((Get-Date) - $t0).TotalSeconds -lt $WatchSeconds) {
    $el = [int]((Get-Date) - $t0).TotalSeconds
    Watch-Usb $known ([ref]$seen)

    # once something interesting is on USB, probe the two known debug networks
    if (($el % 3) -eq 0) {
        foreach ($p in @(@("192.168.2.15", 23), @("10.15.19.82", 8022), @("10.15.19.82", 22))) {
            if (Test-Tcp $p[0] $p[1]) {
                Say ("TCP OPEN {0}:{1}" -f $p[0], $p[1]) Green
                $found = $true
                # the panic handler restarts telnetd on every boot cycle, so
                # allow one new capture per 45 s instead of only ever one
                if (((Get-Date) - $lastTelnet).TotalSeconds -gt 45) {
                    $lastTelnet = Get-Date
                    $telnetDone = $true
                    $stamp = (Get-Date).ToString("HHmmss")
                    try {
                        Telnet-Capture $p[0] $p[1] (Join-Path $HERE "ut-panic-telnet-$stamp.log") 60 | Out-Null
                    } catch {
                        Say ("telnet: capture aborted: {0}" -f $_.Exception.Message) Red
                    }
                }
            }
        }
        if ($el -gt 0 -and (((Get-Date) - $lastPing).TotalSeconds -gt 10)) {
            $lastPing = Get-Date
            $p1 = (Test-Connection -ComputerName 192.168.2.15 -Count 1 -Quiet -ErrorAction SilentlyContinue)
            $p2 = (Test-Connection -ComputerName 10.15.19.82 -Count 1 -Quiet -ErrorAction SilentlyContinue)
            Say ("  t={0,4}s ping 192.168.2.15={1} 10.15.19.82={2}" -f $el, $p1, $p2)
        }
    }
    Start-Sleep -Seconds 1
}

Say "--- watch finished ---" Cyan
Say ("usb devices seen during watch: " + (($seen | ForEach-Object { $_[0] }) -join ", "))
if ($known.Count -gt 0) { Say ("usb devices now: " + (($known.Keys | Sort-Object) -join ", ")) }
Say "log: $Log"
if (-not $found) {
    Say "No debug interface appeared. Next: power-cycle the phone" Yellow
    Say "  (unplug USB, hold Power ~20 s), then Volume Down + Power -> fastboot," Yellow
    Say "  then run  .\boot-android.ps1  to get Android back." Yellow
}
