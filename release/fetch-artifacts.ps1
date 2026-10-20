# Download the klee Ubuntu Touch build artifacts into release/images/.
#
# The artifacts can come from different runs: a kernel build from one run and
# the rootfs/ut_data from a retry run. This script looks at every non-expired
# artifact in the repository and takes the newest copy of each one, so it does
# not matter which run produced what.
#
#   .\fetch-artifacts.ps1
#   .\fetch-artifacts.ps1 -Dest D:\ut\images
#   .\fetch-artifacts.ps1 -Token ghp_xxx        # if git credential is empty
#
# Needs a GitHub token: it is read from the Windows credential store that git
# already uses, or you pass -Token.

[CmdletBinding()]
param(
    [string]$Repo  = "KazeTheLight/ubuntu-touch-poco-x8-pro",
    [string]$Token = "",
    [string]$Dest  = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Dest) { $Dest = Join-Path $HERE "images" }

function Die ($m) { Write-Host "XX  $m" -ForegroundColor Red; exit 1 }

# Artifact name -> files that must end up in images/
$WANTED = [ordered]@{
    "klee-boot-images" = @("ut_boot.img", "ut_init_boot.img", "ut_boot_fastboot-boot.img")
    "klee-rootfs"      = @("ubuntu.img")
    "klee-utdata"      = @("ut_data.img")
    "klee-modules"     = @()            # informational only, not needed to install
}

function Get-GitHubToken {
    if ($Token) { return $Token.Trim() }
    $cred = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
    $line = $cred | Select-String '^password=' | Select-Object -First 1
    if (-not $line) { Die "no GitHub token available - pass -Token <token>" }
    return $line.ToString().Substring("password=".Length).Trim()
}

$T = Get-GitHubToken
$H = @{
    "Authorization" = "Bearer $T"
    "Accept"        = "application/vnd.github+json"
    "User-Agent"    = "klee-fetch-artifacts"
}

Write-Host ""
Write-Host "==> Listing artifacts in $Repo" -ForegroundColor Green

$all = @()
$page = 1
while ($true) {
    $uri = "https://api.github.com/repos/$Repo/actions/artifacts?per_page=100&page=$page"
    $res = Invoke-RestMethod -Uri $uri -Headers $H
    if (-not $res.artifacts) { break }
    $all += $res.artifacts
    if ($all.Count -ge $res.total_count) { break }
    $page++
}

if (-not $all) { Die "no artifacts found (do the workflow runs still exist?)" }

# newest first
$all = $all | Sort-Object created_at -Descending

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("klee-art-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    foreach ($name in $WANTED.Keys) {
        $candidates = $all | Where-Object { $_.name -eq $name -and -not $_.expired }
        if (-not $candidates) {
            $expired = $all | Where-Object { $_.name -eq $name }
            if ($expired) {
                Write-Host "!!  $name exists but has expired" -ForegroundColor Yellow
            } else {
                Write-Host "!!  $name not found - skipped" -ForegroundColor Yellow
            }
            continue
        }

        $a = $candidates | Select-Object -First 1
        $sizeMb = [math]::Round($a.size_in_bytes / 1MB, 1)
        Write-Host ("    {0,-18} {1,7} MB  run {2}" -f $a.name, $sizeMb, $a.workflow_run.id)

        $zip = Join-Path $tmp "$name.zip"
        $ex  = Join-Path $tmp $name
        Invoke-WebRequest -Uri $a.archive_download_url -Headers $H -OutFile $zip
        New-Item -ItemType Directory -Force -Path $ex | Out-Null
        Expand-Archive -Path $zip -DestinationPath $ex -Force

        # artifacts keep their upload layout: copy any file found, flattening it
        Get-ChildItem -Path $ex -Recurse -File | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $Dest $_.Name) -Force
        }
    }
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "==> Files in $Dest" -ForegroundColor Green
$missing = @()
foreach ($name in $WANTED.Keys) {
    foreach ($f in $WANTED[$name]) {
        $p = Join-Path $Dest $f
        if (Test-Path $p) {
            Write-Host ("    {0,-26} {1,10:N1} MB" -f $f, ((Get-Item $p).Length / 1MB))
        } else {
            $missing += $f
        }
    }
}

Write-Host ""
if ($missing.Count -gt 0) {
    Write-Host "!!  Missing: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host "    Run the workflow again (build_rootfs / build_utdata) and re-run this script."
    exit 1
}

Write-Host "All install images are in place. Next:" -ForegroundColor Green
Write-Host "    .\install-windows.ps1 -DryRun"
