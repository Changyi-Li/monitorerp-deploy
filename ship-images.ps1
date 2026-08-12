<#
.SYNOPSIS
  Pull the deployment Docker images on this (fast) Windows machine and ship them
  to the Linux server: docker pull -> save -> scp -> docker load.

  Workaround for a server whose Docker Hub access is slow. Run this from Windows.

.DESCRIPTION
  Ships exactly the images the default deploy needs:
    infiniflow/ragflow:v0.26.4, elasticsearch:8.11.3, mysql:8.0.39,
    pgsty/minio:RELEASE.2026-03-25T00-00-00Z, valkey/valkey:8, postgres:17, nginx.
  Skips any image that is already present on the server (idempotent / resumable).
  Cleans up the tars on both sides after each image loads.

.EXAMPLE
  .\ship-images.ps1

.EXAMPLE
  .\ship-images.ps1 -Server user@1.2.3.4 -SkipPull
#>

param(
    [string]$Server = "",               # always prompted if not passed explicitly
    [string]$RemoteDir = "",            # always prompted if not passed explicitly
    [string]$LocalDir = (Join-Path $PSScriptRoot "images"),
    [switch]$SkipPull                   # assume images are already present locally
)

# --- always ask which server to ship to -------------------------------------
if ([string]::IsNullOrWhiteSpace($Server)) {
    $Server = Read-Host "Enter server (e.g. user@1.2.3.4)"
}
if ([string]::IsNullOrWhiteSpace($Server)) {
    Write-Error "No server given."
    exit 1
}

# --- always ask for the remote temp dir --------------------------------------
if ([string]::IsNullOrWhiteSpace($RemoteDir)) {
    $RemoteDir = Read-Host "Enter remote temp dir for image tars (e.g. /home/user/temp-images)"
}
if ([string]::IsNullOrWhiteSpace($RemoteDir)) {
    Write-Error "No remote temp dir given."
    exit 1
}

# Order matters: smallest first, biggest (ragflow) last, so partial progress
# survives a failure on the last image.
$Images = @(
    "elasticsearch:8.11.3",
    "mysql:8.0.39",
    "pgsty/minio:RELEASE.2026-03-25T00-00-00Z",
    "valkey/valkey:8",
    "nginx",
    "postgres:17",
    "infiniflow/ragflow:v0.26.4"
)

# --- prerequisites ----------------------------------------------------------
foreach ($cmd in @("docker", "ssh", "scp")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "Required command not found: $cmd"
        exit 1
    }
}

# --- helpers ----------------------------------------------------------------
function Get-SafeName([string]$image) {
    # 'infiniflow/ragflow:v0.26.4' -> 'infiniflow_ragflow_v0.26.4'
    return ($image -replace '[^A-Za-z0-9._-]', '_')
}

function Invoke-Check([string]$desc, [scriptblock]$block) {
    Write-Host ("  {0}" -f $desc)
    & $block
    if ($LASTEXITCODE -ne 0) { throw $desc }
}

# --- main -------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null

Write-Host "==> Ensuring remote dir: $RemoteDir"
ssh -o BatchMode=yes $Server "mkdir -p '$RemoteDir'"
if ($LASTEXITCODE -ne 0) { Write-Error "ssh failed — is your key installed? (ssh $Server)"; exit 1 }

$failures = New-Object System.Collections.ArrayList

foreach ($img in $Images) {
    $name       = Get-SafeName $img
    $tarPath    = Join-Path $LocalDir "$name.tar"
    $remoteFile = "$RemoteDir/$name.tar"

    Write-Host "`n=== $img ==="

    # already loaded on the server? skip entirely.
    $exists = ssh -o BatchMode=yes $Server "docker image inspect '$img' >/dev/null 2>&1 && echo yes || echo no"
    if ($exists -match "yes") { Write-Host "  already on server — skipping."; continue }

    try {
        # 1. pull locally (no-op if already pulled)
        if (-not $SkipPull) {
            Invoke-Check "[1/3] docker pull $img" { docker pull $img }
        }

        # 2. save to tar
        Invoke-Check "[2/3] docker save -> $($tarPath)" { docker save -o $tarPath $img }

        # 3. send
        Invoke-Check "[3/3] scp -> $($Server):$remoteFile" {
            scp -o BatchMode=yes $tarPath "${Server}:${remoteFile}"
        }

        # 4. load on the server
        Invoke-Check "      docker load on server" {
            ssh -o BatchMode=yes $Server "docker load -i '$remoteFile'"
        }

        # clean up both sides
        ssh -o BatchMode=yes $Server "rm -f '$remoteFile'"
        if (Test-Path $tarPath) { Remove-Item $tarPath -Force }

        Write-Host "  OK."
    } catch {
        Write-Warning "FAILED on $img — $($_.Exception.Message)"
        [void]$failures.Add($img)
    }
}

Write-Host "`n=============== DONE ==============="
if ($failures.Count -gt 0) {
    Write-Host "Failed images (re-run the script to retry only these):"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
} else {
    Write-Host "All images shipped. On the server run:  cd ~/src/monitorerp-deploy && ./manage.sh up"
}
