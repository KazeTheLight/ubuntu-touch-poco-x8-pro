# watch-build.ps1 - wait for a workflow run and download the boot images.
#
#   .\watch-build.ps1                 # newest run
#   .\watch-build.ps1 -RunId 12345
#   .\watch-build.ps1 -TimeoutMinutes 180
#
# Uses the credentials already stored by Git Credential Manager (the same ones
# `git push` uses); nothing is written to disk.

[CmdletBinding()]
param(
    [string]$RunId = "",
    [int]$TimeoutMinutes = 180,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO = "KazeTheLight/ubuntu-touch-poco-x8-pro"
if (-not $OutDir) { $OutDir = Join-Path $HERE "build-artifacts" }

function Say($m, $c = "Gray") {
    Write-Host ("{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m) -ForegroundColor $c
}

function Get-Token {
    $inp = "protocol=https`nhost=github.com`n`n"
    $out = $inp | git credential fill 2>&1
    $tok = (($out | Where-Object { $_ -like "password=*" }) -split "=",2)[1]
    if (-not $tok) { throw "no github credentials in the credential manager" }
    return $tok
}

$tok = Get-Token
$hdr = @{ Authorization = "Bearer $tok"; Accept = "application/vnd.github+json"; "User-Agent" = "opencode" }

function Api($path) {
    Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/$path" -Headers $hdr -Method Get
}

if (-not $RunId) {
    $runs = Api "actions/runs?per_page=1"
    $RunId = "$($runs.workflow_runs[0].id)"
}
Say "watching run $RunId" Cyan

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$lastLine = ""
while ((Get-Date) -lt $deadline) {
    $r = Api "actions/runs/$RunId"
    $line = "status={0} conclusion={1}" -f $r.status, $r.conclusion
    if ($line -ne $lastLine) { Say ("  " + $line); $lastLine = $line }
    if ($r.status -eq "completed") { break }
    Start-Sleep -Seconds 45
}
$r = Api "actions/runs/$RunId"
Say ("final: status={0} conclusion={1}" -f $r.status, $r.conclusion) $(if ($r.conclusion -eq "success") { "Green" } else { "Red" })

if ($r.conclusion -ne "success") {
    Say "run did not succeed - fetch the job logs from the Actions page" Yellow
    exit 1
}

$arts = Api "actions/runs/$RunId/artifacts"
Say "artifacts:"
$arts.artifacts | ForEach-Object { Say ("  {0}  ({1:N0} bytes)" -f $_.name, $_.size_in_bytes) }

$want = $arts.artifacts | Where-Object { $_.name -eq "klee-boot-images" }
if (-not $want) { Say "klee-boot-images artifact missing" Red; exit 1 }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir "klee-boot-images.zip"
Say "downloading $($want.name) ..."
$old = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
try {
    Invoke-WebRequest -Uri "https://api.github.com/repos/$REPO/actions/artifacts/$($want.id)/zip" `
        -Headers $hdr -OutFile $zip
} finally { $ErrorActionPreference = $old }
Say ("  saved {0:N0} bytes -> {1}" -f (Get-Item $zip).Length, $zip)
Expand-Archive -Path $zip -DestinationPath $OutDir -Force
Get-ChildItem $OutDir -Filter "ut_*.img" | ForEach-Object {
    Say ("  {0,-28} {1,12:N0} bytes" -f $_.Name, $_.Length) Green
}
Say "done" Green
