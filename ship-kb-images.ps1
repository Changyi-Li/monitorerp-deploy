<#
.SYNOPSIS
  Ship the MonitorERP-KB app images from this (fast) Windows machine to the
  Linux server and deploy the stack: docker pull -> save -> scp -> docker load
  -> docker compose up -d.

  Workaround for a server whose GHCR access is slow. Run this from Windows.

.DESCRIPTION
  Ships the two app images for one release:
    ghcr.io/changyi-li/kb-api:<tag>, ghcr.io/changyi-li/kb-web:<tag>
  (public on GHCR — no docker login needed), then DEPLOYS: writes KB_TAG into
  kb/.env on the server, runs docker compose up -d in the kb stack and waits
  on the web healthcheck. Roll back by re-running with the previous tag.

  Skips any image that is already present on the server (idempotent / resumable).
  App-image tars stay in the local images/ dir (newest 3 per image) as
  rollback insurance.

  The infra images (ragflow, postgres, nginx, ...) are shipped by
  ship-images.ps1 — run that first if the server has never been provisioned.

.EXAMPLE
  .\ship-kb-images.ps1 -Tag v1.2.3

.EXAMPLE
  .\ship-kb-images.ps1 -Tag v1.0.0 -Server user@1.2.3.4 -SkipPull
#>

param(
    [string]$Server = "",               # always prompted if not passed explicitly
    [string]$RemoteDir = "",            # always prompted if not passed explicitly
    [string]$LocalDir = (Join-Path $PSScriptRoot "images"),
    [string]$Tag = "",                  # KB_TAG — always prompted if not passed explicitly
    [string]$RemoteDeployDir = "~/src/monitorerp-deploy",
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

# --- KB_TAG is the whole point of this script --------------------------------
if ([string]::IsNullOrWhiteSpace($Tag)) {
    $Tag = Read-Host "Enter KB_TAG (e.g. v1.2.3 — the release git tag)"
}
if ([string]::IsNullOrWhiteSpace($Tag)) {
    Write-Error "No KB_TAG given."
    exit 1
}
# Tag values are semver — no slashes, no spaces; anything else is a typo.
# (Also keeps the server-side sed replacement safe.)
if ($Tag -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Error "KB_TAG must look like a git tag (e.g. v1.2.3), got: $Tag"
    exit 1
}

$Images = @(
    "ghcr.io/changyi-li/kb-api:$Tag",
    "ghcr.io/changyi-li/kb-web:$Tag"
)
$ImagePrefixes = @("ghcr.io_changyi-li_kb-api_", "ghcr.io_changyi-li_kb-web_")

# --- prerequisites ----------------------------------------------------------
foreach ($cmd in @("docker", "ssh", "scp")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "Required command not found: $cmd"
        exit 1
    }
}

# --- helpers ----------------------------------------------------------------
function Get-SafeName([string]$image) {
    # 'ghcr.io/changyi-li/kb-api:v1.2.3' -> 'ghcr.io_changyi-li_kb-api_v1.2.3'
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

        # clean up: remote tar always; local tar stays as rollback insurance,
        # pruned to the newest 3 per image below
        ssh -o BatchMode=yes $Server "rm -f '$remoteFile'"

        # keep only the newest 3 tars per image
        foreach ($prefix in $ImagePrefixes) {
            if ($name.StartsWith($prefix)) {
                Get-ChildItem $LocalDir -Filter "$prefix*.tar" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime | Select-Object -SkipLast 3 |
                    ForEach-Object { Remove-Item $_.FullName -Force }
            }
        }

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

# --- deploy the KB stack -----------------------------------------------------
Write-Host "`n=== Deploying MonitorERP-KB (KB_TAG=$Tag) ==="

$kbEnv = "$RemoteDeployDir/kb/.env"
$hasEnv = ssh -o BatchMode=yes $Server "test -f $kbEnv && echo yes || echo no"
if ($hasEnv -notmatch "yes") {
    Write-Error "$kbEnv not found on the server — run kb/bootstrap.sh there first (interactive, writes the admin password once). Images are shipped; deploy aborted."
    exit 1
}

# 1. write KB_TAG (tag values are semver — no slash; sed is safe)
$setTag = "grep -q '^KB_TAG=' $kbEnv && sed -i 's|^KB_TAG=.*|KB_TAG=$Tag|' $kbEnv || echo 'KB_TAG=$Tag' >> $kbEnv"
if (-not (Invoke-Remote $setTag)) {
    Write-Error "Failed to set KB_TAG in $kbEnv"
    exit 1
}
Write-Host "  KB_TAG=$Tag written to $kbEnv"

# 2. recreate the stack with the new images
if (-not (Invoke-Remote "cd $RemoteDeployDir/kb && docker compose up -d")) {
    Write-Error "docker compose up -d failed in $RemoteDeployDir/kb — check 'docker compose logs' there."
    exit 1
}

# 3. wait on the web healthcheck (sign-in page, same URL as the compose check)
Write-Host "  Waiting for the KB web app on 127.0.0.1:4800/auth/sign-in ..."
$up = $false
for ($i = 0; $i -lt 30; $i++) {
    $probe = ssh -o BatchMode=yes $Server "curl -sf -o /dev/null http://127.0.0.1:4800/auth/sign-in && echo up || echo down"
    if ($probe -match "up") { $up = $true; break }
    Start-Sleep -Seconds 2
}

Write-Host "`n=============== DONE ==============="
if ($up) {
    Write-Host "Deploy OK — MonitorERP-KB is up on kb.ai.monitorsystem.cn (KB_TAG=$Tag)."
    Write-Host "Rollback: re-run with -Tag <previous-tag>, or flip KB_TAG in $kbEnv and run 'docker compose up -d' there."
} else {
    Write-Warning "Images shipped and KB_TAG set, but the web app did not answer in time."
    Write-Warning "Check on the server:  cd $RemoteDeployDir/kb && docker compose logs --tail=100"
    exit 1
}
