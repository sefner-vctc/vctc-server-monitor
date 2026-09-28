param(
    [Parameter(Mandatory = $true)]
    [string]$MonitorUrl,

    [Parameter(Mandatory = $true)]
    [string]$ServerApiKey,

    [Parameter(Mandatory = $true)]
    [string]$BackupSourcePath,

    [string]$ScriptsDir = "C:\Scripts",
    [string]$ResticExeSource = "",
    [string]$ResticRepository = "",
    [string]$ResticPassword = "",
    [string]$WasabiAccessKey = "",
    [string]$WasabiSecretKey = "",
    [string[]]$ServicesToMonitor = @("W32Time", "LanmanServer", "WinRM"),
    [string[]]$ScheduledTasksToMonitor = @("VCTC Server Monitor Agent|VCTC Monitor Agent", "VCTC Restic Backup|Restic Backup"),
    [string]$BackupTaskTime = "02:00",
    [string]$AgentTaskIntervalMinutes = "30"
)

$ErrorActionPreference = "Stop"

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Resolve-SourceScript([string]$FileName) {
    $candidates = @(
        (Join-Path $PSScriptRoot $FileName),
        (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts") $FileName)
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "Could not find source script $FileName. Place it beside install-windows-server.ps1 or run the installer from the repo checkout."
}

function Copy-IfDifferent([string]$Source, [string]$Destination) {
    $resolvedSource = [System.IO.Path]::GetFullPath($Source)
    $resolvedDestination = [System.IO.Path]::GetFullPath($Destination)

    if ($resolvedSource -ieq $resolvedDestination) {
        return
    }

    Copy-Item $Source $Destination -Force
}

Ensure-Directory $ScriptsDir
Ensure-Directory (Join-Path $ScriptsDir "Logs")
Ensure-Directory (Join-Path $ScriptsDir "Logs\restic")

Copy-IfDifferent (Resolve-SourceScript "agent.ps1") (Join-Path $ScriptsDir "agent.ps1")
Copy-IfDifferent (Resolve-SourceScript "restic-backup.ps1") (Join-Path $ScriptsDir "restic-backup.ps1")

if ($ResticExeSource) {
    Copy-IfDifferent $ResticExeSource (Join-Path $ScriptsDir "restic.exe")
}

$agentConfig = @"
`$API_URL = "$MonitorUrl/api/it/checkin"
`$API_KEY = "$ServerApiKey"
`$RESTIC_ENV_PATH = "$ScriptsDir\restic-env.ps1"
`$RESTIC_EXE_PATH = "$ScriptsDir\restic.exe"
`$RESTIC_LOG_DIR = "$ScriptsDir\Logs\restic"
`$ENABLE_RESTIC_MONITORING = `$true
`$SERVICES_TO_MONITOR = @(
$(($ServicesToMonitor | ForEach-Object { '    "' + $_ + '"' }) -join ",`r`n")
)
`$SCHEDULED_TASKS_TO_MONITOR = @(
$(($ScheduledTasksToMonitor | ForEach-Object { '    "' + $_ + '"' }) -join ",`r`n")
)
"@
Set-Content -Path (Join-Path $ScriptsDir "agent-config.ps1") -Value $agentConfig -Encoding UTF8

$resticConfig = @"
`$RESTIC_ENV_PATH = "$ScriptsDir\restic-env.ps1"
`$RESTIC_EXE_PATH = "$ScriptsDir\restic.exe"
`$RESTIC_LOG_DIR = "$ScriptsDir\Logs\restic"
`$BACKUP_SOURCE_PATH = "$BackupSourcePath"
`$RESTIC_KEEP_DAILY = 7
`$RESTIC_KEEP_WEEKLY = 4
`$RESTIC_KEEP_MONTHLY = 12
"@
Set-Content -Path (Join-Path $ScriptsDir "restic-config.ps1") -Value $resticConfig -Encoding UTF8

if ($ResticRepository -and $ResticPassword -and $WasabiAccessKey -and $WasabiSecretKey) {
    $resticEnv = @"
`$env:RESTIC_REPOSITORY = "$ResticRepository"
`$env:RESTIC_PASSWORD = "$ResticPassword"
`$env:AWS_ACCESS_KEY_ID = "$WasabiAccessKey"
`$env:AWS_SECRET_ACCESS_KEY = "$WasabiSecretKey"
"@
    Set-Content -Path (Join-Path $ScriptsDir "restic-env.ps1") -Value $resticEnv -Encoding UTF8
}

$agentAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$ScriptsDir\agent.ps1`""
$agentTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes ([int]$AgentTaskIntervalMinutes)) -RepetitionDuration (New-TimeSpan -Days 3650)
$agentSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask -TaskName "VCTC Server Monitor Agent" -Action $agentAction -Trigger $agentTrigger -Settings $agentSettings -User "SYSTEM" -RunLevel Highest -Force | Out-Null

$backupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$ScriptsDir\restic-backup.ps1`""
$backupTrigger = New-ScheduledTaskTrigger -Daily -At $BackupTaskTime
Register-ScheduledTask -TaskName "VCTC Restic Backup" -Action $backupAction -Trigger $backupTrigger -Settings $agentSettings -User "SYSTEM" -RunLevel Highest -Force | Out-Null

Write-Host "Installation complete."
Write-Host "Scripts directory: $ScriptsDir"
Write-Host "Agent task: VCTC Server Monitor Agent"
Write-Host "Backup task: VCTC Restic Backup"
Write-Host "If this server uses a brand-new Wasabi bucket, run '. $ScriptsDir\restic-env.ps1' and then '$ScriptsDir\restic.exe init' once before the first backup."
Write-Host "Then run the backup task once, then run the agent task once to validate monitoring."
