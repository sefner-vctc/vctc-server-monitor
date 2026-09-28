# VCTC Restic Backup Script
# Scheduled Task: runs daily at 2:00 AM as SYSTEM
# Task Action: powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\restic-backup.ps1"

$configPath = "C:\Scripts\restic-config.ps1"
if (Test-Path $configPath) {
    . $configPath
}

if (-not $RESTIC_ENV_PATH) {
    $RESTIC_ENV_PATH = "C:\Scripts\restic-env.ps1"
}

if (-not $RESTIC_EXE_PATH) {
    $RESTIC_EXE_PATH = "C:\Scripts\restic.exe"
}

if (-not $BACKUP_SOURCE_PATHS) {
    if ($BACKUP_SOURCE_PATH) {
        $BACKUP_SOURCE_PATHS = @($BACKUP_SOURCE_PATH)
    } else {
        throw "BACKUP_SOURCE_PATHS is not set. Define it in C:\Scripts\restic-config.ps1."
    }
}

if (-not $RESTIC_LOG_DIR) {
    $RESTIC_LOG_DIR = "C:\Scripts\Logs\restic"
}

if (-not $RESTIC_KEEP_DAILY) { $RESTIC_KEEP_DAILY = 7 }
if (-not $RESTIC_KEEP_WEEKLY) { $RESTIC_KEEP_WEEKLY = 4 }
if (-not $RESTIC_KEEP_MONTHLY) { $RESTIC_KEEP_MONTHLY = 12 }

if (Test-Path $RESTIC_ENV_PATH) {
    . $RESTIC_ENV_PATH
} else {
    throw "Restic environment file not found at $RESTIC_ENV_PATH."
}

if (-not $env:RESTIC_REPOSITORY) {
    throw "RESTIC_REPOSITORY is not set in $RESTIC_ENV_PATH."
}

if ($env:RESTIC_REPOSITORY -notmatch '^s3:https://') {
    throw "RESTIC_REPOSITORY must start with 's3:https://'. Current value: $($env:RESTIC_REPOSITORY)"
}

$logDir = $RESTIC_LOG_DIR
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$startTime    = Get-Date
$logFile      = Join-Path $logDir ("backup-" + $startTime.ToString("yyyy-MM-dd-HHmmss") + ".json")
$startTimeStr = $startTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# ── Run Backup ────────────────────────────────────────────────────────────────
$backupOutput = & $RESTIC_EXE_PATH backup @($BACKUP_SOURCE_PATHS) --use-fs-snapshot --json 2>&1
$exitCode     = $LASTEXITCODE
$summaryLine  = $backupOutput | Where-Object { $_ -match '"message_type":"summary"' } | Select-Object -Last 1

$status          = if ($exitCode -eq 0) { "success" } else { "error" }
$filesNew        = 0
$filesChanged    = 0
$dataAddedBytes  = [long]0
$totalFiles      = 0
$snapshotId      = $null
$errorMsg        = $null

if ($exitCode -ne 0) {
    $errorMsg = ($backupOutput | Where-Object { $_ -notmatch '"message_type"' } | Select-Object -First 5) -join " "
    if ($errorMsg -match 'repository does not exist') {
        $errorMsg += " Hint: if this is a brand-new Wasabi bucket, run '. $RESTIC_ENV_PATH' and then '$RESTIC_EXE_PATH init' once before the first backup."
    }
} elseif ($summaryLine) {
    $s               = $summaryLine | ConvertFrom-Json
    $filesNew        = [int]$s.files_new
    $filesChanged    = [int]$s.files_changed
    $dataAddedBytes  = [long]$s.data_added
    $totalFiles      = [int]$s.total_files_processed
    $snapshotId      = $s.snapshot_id
}

if ($exitCode -ne 0) {
    Write-Error $errorMsg
}

# ── Run Forget / Prune ────────────────────────────────────────────────────────
& $RESTIC_EXE_PATH forget --keep-daily $RESTIC_KEEP_DAILY --keep-weekly $RESTIC_KEEP_WEEKLY --keep-monthly $RESTIC_KEEP_MONTHLY --prune --quiet 2>&1 | Out-Null

# ── Write Log ─────────────────────────────────────────────────────────────────
$endTime = Get-Date
$result  = [ordered]@{
    start_time       = $startTimeStr
    end_time         = $endTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    duration_seconds = [int]($endTime - $startTime).TotalSeconds
    status           = $status
    files_new        = $filesNew
    files_changed    = $filesChanged
    data_added_bytes = $dataAddedBytes
    total_files      = $totalFiles
    snapshot_id      = $snapshotId
    error            = $errorMsg
}
$result | ConvertTo-Json | Set-Content -Path $logFile -Encoding UTF8

if ($exitCode -ne 0) {
    exit $exitCode
}

# ── Clean Up Old Logs (keep 90 days) ─────────────────────────────────────────
Get-ChildItem $logDir -Filter "backup-*.json" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
    Remove-Item -Force
