<#
.SYNOPSIS
  Ship the Keycloak image from this (fast) Windows machine to the Linux server
  and deploy the stack: docker pull -> save -> scp -> docker load
  -> docker compose up -d.

  Workaround for a server whose quay.io access is slow. Run this from Windows.

.DESCRIPTION
  Ships the Keycloak image:
    quay.io/keycloak/keycloak:<Version>
  (public on quay.io — no docker login needed), then DEPLOYS: runs
  docker compose up -d in the keycloak stack and waits on the health endpoint.
  Roll back by re-running with the previous -Version.

  Skips the image if it is already present on the server (idempotent / resumable).
  Image tars stay in the local images/ dir (newest 3 per image) as rollback
  insurance.

  -Version must match the tag pinned in keycloak/docker-compose.yml — the
  script checks the local file and refuses to deploy a mismatch, because
  'docker compose up -d' would otherwise silently keep the pinned version.
  The deploy also needs keycloak/.env on the server: run keycloak/bootstrap.sh
  there once before the first deploy (creates the admin credentials).

.EXAMPLE
  .\ship-keycloak-images.ps1

.EXAMPLE
  .\ship-keycloak-images.ps1 -Version 26.7.2 -Server user@1.2.3.4 -SkipPull
#>

param(
    [string]$Server = "",               # always prompted if not passed explicitly
    [string]$RemoteDir = "",            # always prompted if not passed explicitly
    [string]$LocalDir = (Join-Path $PSScriptRoot "images"),
    [string]$Version = "26.7.1",        # must match the pin in keycloak/docker-compose.yml
    [string]$RemoteDeployDir = "~/src/monitorerp-deploy",
    [switch]$SkipPull                   # assume the image is already present locally
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

# --- version sanity ----------------------------------------------------------
if ($Version -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Error "Version must look like an image tag (e.g. 26.7.1), got: $Version"
    exit 1
}

# The compose file pins the version — deploy only what it pins.
$composeFile = Join-Path $PSScriptRoot "keycloak\docker-compose.yml"
if (-not (Test-Path $composeFile)) {
    Write-Error "keycloak/docker-compose.yml not found next to this script — cannot verify the pinned version."
    exit 1
}
$pin = Select-String -Path $composeFile -Pattern 'quay.io/keycloak/keycloak:(\S+)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
if ($pin -and $pin -ne $Version) {
    Write-Error "keycloak/docker-compose.yml pins $pin but -Version $Version was given. Update the compose file (and git pull on the server) so they match, then re-run."
    exit 1
}

$Images = @("quay.io/keycloak/keycloak:$Version")
$ImagePrefixes = @("quay.io_keycloak_keycloak_")

# --- prerequisites ----------------------------------------------------------
foreach ($cmd in @("docker", "ssh", "scp")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "Required command not found: $cmd"
        exit 1
    }
}

# --- helpers ----------------------------------------------------------------
function Get-SafeName([string]$image) {
    # 'quay.io/keycloak/keycloak:26.7.1' -> 'quay.io_keycloak_keycloak_26.7.1'
    return ($image -replace '[^A-Za-z0-9._-]', '_')
}

function Invoke-Check([string]$desc, [scriptblock]$block) {
    Write-Host ("  {0}" -f $desc)
    & $block
    if ($LASTEXITCODE -ne 0) { throw $desc }
}

function Invoke-Remote([string]$remoteCmd) {
    ssh -o BatchMode=yes $Server $remoteCmd
    return $LASTEXITCODE -eq 0
}

# --- ship the image ----------------------------------------------------------
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

        # clean up: remote tar always; local tar stays as rollback insurance,
        # pruned to the newest 3 below
        ssh -o BatchMode=yes $Server "rm -f '$remoteFile'"
        Get-ChildItem $LocalDir -Filter "$($ImagePrefixes[0])*.tar" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -SkipLast 3 |
            ForEach-Object { Remove-Item $_.FullName -Force }

        Write-Host "  OK."
    } catch {
        Write-Warning "FAILED on $img — $($_.Exception.Message)"
        [void]$failures.Add($img)
    }
}

if ($failures.Count -gt 0) {
    Write-Host "`n=============== FAILED ==============="
    Write-Host "Failed images (re-run the script to retry only these):"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}

# --- deploy the keycloak stack ------------------------------------------------
Write-Host "`n=== Deploying Keycloak ($Version) ==="

$kcEnv = "$RemoteDeployDir/keycloak/.env"
$hasEnv = ssh -o BatchMode=yes $Server "test -f $kcEnv && echo yes || echo no"
if ($hasEnv -notmatch "yes") {
    Write-Error "$kcEnv not found on the server — run keycloak/bootstrap.sh there first (creates the admin credentials). Image is shipped; deploy aborted."
    exit 1
}

# 1. recreate the stack with the shipped image
if (-not (Invoke-Remote "cd $RemoteDeployDir/keycloak && docker compose up -d")) {
    Write-Error "docker compose up -d failed in $RemoteDeployDir/keycloak — check 'docker compose logs' there."
    exit 1
}

# 2. verify the running container really uses the shipped image (a stale compose
#    pin on the server would silently keep the old one)
$runningImage = ssh -o BatchMode=yes $Server "docker inspect keycloak --format '{{.Config.Image}}' 2>/dev/null"
if ($runningImage -ne $Images[0]) {
    Write-Warning "Running container image is '$runningImage', expected '$($Images[0])'."
    Write-Warning "The server's keycloak/docker-compose.yml may be stale — git pull there, then re-run."
}

# 3. wait on the health endpoint (200 only once Keycloak is fully ready)
Write-Host "  Waiting for Keycloak on http://127.0.0.1:8081/health/ready ..."
$up = $false
for ($i = 0; $i -lt 60; $i++) {
    $probe = ssh -o BatchMode=yes $Server "curl -sf -o /dev/null http://127.0.0.1:8081/health/ready && echo up || echo down"
    if ($probe -match "up") { $up = $true; break }
    Start-Sleep -Seconds 2
}

Write-Host "`n=============== DONE ==============="
if ($up) {
    Write-Host "Deploy OK — Keycloak is up on http://127.0.0.1:8081 (admin console)."
    Write-Host "Rollback: re-run with -Version <previous>, or flip the image pin in keycloak/docker-compose.yml and 'docker compose up -d' there."
} else {
    Write-Warning "Image shipped, but Keycloak did not answer in time."
    Write-Warning "Check on the server:  cd $RemoteDeployDir/keycloak && docker compose logs --tail=100"
    exit 1
}
