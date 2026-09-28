# VCTC Server Monitor Agent
# Schedule as a Windows Scheduled Task every 30 minutes.
# Task Action: powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\agent.ps1"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 
$configPath = "C:\Scripts\agent-config.ps1"
if (Test-Path $configPath) {
    . $configPath
}

if (-not $API_URL) {
    $API_URL = "http://10.0.0.23:3000/api/it/checkin"
}

if (-not $API_KEY) {
    throw "API_KEY is not configured. Define it in C:\Scripts\agent-config.ps1."
}

if (-not $RESTIC_ENV_PATH) {
    $RESTIC_ENV_PATH = "C:\Scripts\restic-env.ps1"
}

if (-not $RESTIC_EXE_PATH) {
    $RESTIC_EXE_PATH = "C:\Scripts\restic.exe"
}

if (-not $RESTIC_LOG_DIR) {
    $RESTIC_LOG_DIR = "C:\Scripts\Logs\restic"
}

if ($null -eq $ENABLE_RESTIC_MONITORING) {
    $ENABLE_RESTIC_MONITORING = $true
}

function Normalize-JsonString([object]$Value) {
    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString()
    $builder = New-Object System.Text.StringBuilder

    for ($i = 0; $i -lt $text.Length; $i++) {
        $char = $text[$i]

        if ([char]::IsHighSurrogate($char)) {
            if (($i + 1) -lt $text.Length -and [char]::IsLowSurrogate($text[$i + 1])) {
                [void]$builder.Append($char)
                $i += 1
                [void]$builder.Append($text[$i])
            }
            continue
        }

        if ([char]::IsLowSurrogate($char)) {
            continue
        }

        [void]$builder.Append($char)
    }

    return $builder.ToString()
}

function Get-FirstValue([object]$Value) {
    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            return $item
        }
    }

    return $Value
}

function Test-JsonField([string]$Name, [object]$Value) {
    try {
        @{ value = $Value } | ConvertTo-Json -Depth 8 -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "JSON serialization failed for field '$Name': $_"
        exit 1
    }
}

function Test-JsonArrayItems([string]$Name, [object[]]$Items) {
    for ($index = 0; $index -lt $Items.Count; $index++) {
        try {
            @{ value = $Items[$index] } | ConvertTo-Json -Depth 8 -ErrorAction Stop | Out-Null
        } catch {
            Write-Error "JSON serialization failed for item '$Name[$index]': $_"
            Write-Error ($Items[$index] | Out-String)
            exit 1
        }
    }
}

function Format-DateTimeValue([object]$Value) {
    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        if ($Value.Year -le 1601) {
            return $null
        }
        return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    $text = Normalize-JsonString $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [ref]$parsed)) {
        if ($parsed.Year -le 1601) {
            return $null
        }
        return $parsed.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    return $text
}

function Split-TaskNameSpec([string]$TaskSpec) {
    if ([string]::IsNullOrWhiteSpace($TaskSpec)) {
        return @()
    }

    return @($TaskSpec -split '\|' | ForEach-Object {
        $candidate = Normalize-JsonString $_
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidate.Trim()
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# ── OS Info ───────────────────────────────────────────────────────────────────
$os = Get-CimInstance Win32_OperatingSystem
$osInfo = Normalize-JsonString "$($os.Caption) (Build $($os.BuildNumber))"
$uptimeSeconds = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds

# ── CPU & RAM ─────────────────────────────────────────────────────────────────
$cpuUsage = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
$ramUsedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)

# ── Disk Usage ────────────────────────────────────────────────────────────────
$disks = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null -and $_.Free -ne $null } | ForEach-Object {
    $total = $_.Used + $_.Free
    $usedPct = if ($total -gt 0) { [math]::Round(($_.Used / $total) * 100, 1) } else { 0 }
    @{
        drive    = (Normalize-JsonString $_.Root).TrimEnd('\')
        total_gb = [math]::Round($total / 1GB, 2)
        free_gb  = [math]::Round($_.Free / 1GB, 2)
        used_pct = $usedPct
    }
}

# ── Physical Disk Health ──────────────────────────────────────────────────────
$physicalDisks = @()
try {
    $physicalDisks = @(Get-PhysicalDisk | ForEach-Object {
        $sizeGb = if ($_.Size -gt 0) { [math]::Round($_.Size / 1GB, 0) } else { $null }
        $opStatus = $_.OperationalStatus
        $opStatusStr = if ($opStatus -is [System.Collections.IEnumerable] -and $opStatus -isnot [string]) {
            Normalize-JsonString (($opStatus | Select-Object -First 1).ToString())
        } else {
            Normalize-JsonString $opStatus.ToString()
        }
        @{
            friendly_name      = Normalize-JsonString $_.FriendlyName
            health_status      = Normalize-JsonString $_.HealthStatus.ToString()
            operational_status = $opStatusStr
            media_type         = Normalize-JsonString $_.MediaType.ToString()
            size_gb            = $sizeGb
        }
    })
} catch {
    Write-Warning "Could not query physical disk health: $_"
}

# ── Windows Updates ───────────────────────────────────────────────────────────
$pendingUpdates = $null
$lastUpdateInstalled = $null
try {
    $updateSession  = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $searchResult   = $updateSearcher.Search("IsInstalled=0 and Type='Software'")
    $pendingUpdates = $searchResult.Updates.Count

    $historyCount = $updateSearcher.GetTotalHistoryCount()
    if ($historyCount -gt 0) {
        $history = $updateSearcher.QueryHistory(0, [math]::Min($historyCount, 20)) |
            Where-Object { $_.ResultCode -eq 2 } |
            Sort-Object Date -Descending |
            Select-Object -First 1
        if ($history) { $lastUpdateInstalled = $history.Date.ToString("yyyy-MM-ddTHH:mm:ss") }
    }
} catch {
    Write-Warning "Could not query Windows Updates: $_"
}

# ── Services to Monitor ───────────────────────────────────────────────────────
if (-not $SERVICES_TO_MONITOR) {
    $SERVICES_TO_MONITOR = @(
        "W32Time",      # Windows Time
        "LanmanServer", # Server (file sharing)
        "WinRM",        # Windows Remote Management
        "zenengine"     # Actian Zen Workgroup Engine (Sage 50)
    )
}

$services = $SERVICES_TO_MONITOR | ForEach-Object {
    $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
    if ($svc) {
        @{
            name         = Normalize-JsonString $svc.Name
            display_name = Normalize-JsonString $svc.DisplayName
            status       = Normalize-JsonString $svc.Status.ToString()
        }
    }
} | Where-Object { $_ -ne $null }

# ── Scheduled Tasks to Monitor ────────────────────────────────────────────────
if (-not $SCHEDULED_TASKS_TO_MONITOR) {
    $SCHEDULED_TASKS_TO_MONITOR = @(
        "VCTC Server Monitor Agent|VCTC Monitor Agent",
        "VCTC Restic Backup|Restic Backup"
    )
}

$scheduledTasks = @()
try {
    $scheduledTasks = $SCHEDULED_TASKS_TO_MONITOR | ForEach-Object {
        $taskSpec = $_
        $taskNameCandidates = Split-TaskNameSpec $taskSpec
        $task = $null

        foreach ($taskName in $taskNameCandidates) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) {
                break
            }
        }

        if (-not $task) {
            return @{
                name             = if ($taskNameCandidates.Count -gt 0) { $taskNameCandidates[0] } else { Normalize-JsonString $taskSpec }
                state            = "Missing"
                enabled          = $false
                last_run_time    = $null
                next_run_time    = $null
                last_task_result = $null
            }
        }

        $taskInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        @{
            name             = Normalize-JsonString $task.TaskName
            state            = Normalize-JsonString $task.State.ToString()
            enabled          = [bool]$task.Settings.Enabled
            last_run_time    = Format-DateTimeValue $taskInfo.LastRunTime
            next_run_time    = Format-DateTimeValue $taskInfo.NextRunTime
            last_task_result = if ($taskInfo -and $null -ne $taskInfo.LastTaskResult) { [int]$taskInfo.LastTaskResult } else { $null }
        }
    } | Where-Object { $_ -ne $null }

    $scheduledTasks = @($scheduledTasks)
} catch {
    Write-Warning "Could not query scheduled tasks: $_"
}

# ── Domain Services Health ────────────────────────────────────────────────────
$domainServices = $null
try {
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $isDomainController = @('4', '5') -contains $computerSystem.DomainRole.ToString()

    if ($isDomainController) {
        $dnsService = Get-Service -Name "DNS" -ErrorAction SilentlyContinue
        $adwsService = Get-Service -Name "ADWS" -ErrorAction SilentlyContinue
        $shares = Get-CimInstance Win32_Share -ErrorAction SilentlyContinue
        $shareNames = @($shares | ForEach-Object { Normalize-JsonString $_.Name })
        $domainName = if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
            Normalize-JsonString $env:USERDNSDOMAIN
        } else {
            Normalize-JsonString $computerSystem.Domain
        }

        $localDnsQueryOk = $null
        if ($dnsService) {
            try {
                $dnsResult = Resolve-DnsName -Name $domainName -Server "127.0.0.1" -ErrorAction Stop
                $localDnsQueryOk = @($dnsResult).Count -gt 0
            } catch {
                $localDnsQueryOk = $false
            }
        }

        $domainServices = @{
            is_domain_controller = $true
            domain_name          = $domainName
            dns_service_status   = if ($dnsService) { Normalize-JsonString $dnsService.Status.ToString() } else { $null }
            adws_service_status  = if ($adwsService) { Normalize-JsonString $adwsService.Status.ToString() } else { $null }
            sysvol_share_present = $shareNames -contains "SYSVOL"
            netlogon_share_present = $shareNames -contains "NETLOGON"
            local_dns_query_ok   = $localDnsQueryOk
        }
    }
} catch {
    Write-Warning "Could not query domain services health: $_"
}

# ── Event Log Errors ──────────────────────────────────────────────────────────
# Collect Error and Critical events from System and Application logs, last hour
$eventLogErrors = @()
try {
    $since = (Get-Date).AddHours(-1)
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'System', 'Application'
        Level     = 1, 2   # 1=Critical, 2=Error
        StartTime = $since
    } -MaxEvents 20 -ErrorAction SilentlyContinue

    if ($events) {
        # Group by source+id so repeated events show as a count instead of duplicates
        $eventLogErrors = $events | Group-Object { "$($_.ProviderName)|$($_.Id)" } | ForEach-Object {
            $latest = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $firstLine = Normalize-JsonString (($latest.Message -split "`n")[0].Trim())
            if ($firstLine.Length -gt 200) { $firstLine = $firstLine.Substring(0, 200) + "..." }
            @{
                time    = $latest.TimeCreated.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                log     = Normalize-JsonString $latest.LogName
                source  = Normalize-JsonString $latest.ProviderName
                id      = [int]$latest.Id
                level   = if ($latest.Level -eq 1) { "Critical" } else { "Error" }
                message = $firstLine
                count   = [int]$_.Count
            }
        } | Sort-Object { $_["time"] } -Descending | Select-Object -First 10
        $eventLogErrors = @($eventLogErrors)
    }
} catch {
    Write-Warning "Could not query Event Log: $_"
}

# ── Restic Backup History (from log files) ────────────────────────────────────
$resticBackupHistory = @()
if ($ENABLE_RESTIC_MONITORING) {
try {
    $logDir = $RESTIC_LOG_DIR
    if (Test-Path $logDir) {
        $since = (Get-Date).AddDays(-30)
        $resticBackupHistory = Get-ChildItem $logDir -Filter "backup-*.json" |
            Where-Object { $_.LastWriteTime -ge $since } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 30 |
            ForEach-Object {
                $r = Get-Content $_.FullName -Raw | ConvertFrom-Json
                @{
                    start_time       = $r.start_time
                    end_time         = $r.end_time
                    duration_seconds = [int]$r.duration_seconds
                    status           = $r.status
                    files_new        = [int]$r.files_new
                    files_changed    = [int]$r.files_changed
                    data_added_bytes = [long]$r.data_added_bytes
                    total_files      = [int]$r.total_files
                    snapshot_id      = if ($r.snapshot_id) { Normalize-JsonString $r.snapshot_id } else { $null }
                    error            = if ($r.error) { Normalize-JsonString $r.error } else { $null }
                }
            }
        $resticBackupHistory = @($resticBackupHistory)
    }
} catch {
    Write-Warning "Could not read backup logs: $_"
}
}

# ── Restic Backup Status ──────────────────────────────────────────────────────
$resticSnapshots = @()
if ($ENABLE_RESTIC_MONITORING) {
try {
    if (Test-Path $RESTIC_ENV_PATH) {
        . $RESTIC_ENV_PATH
    }
    $json = & $RESTIC_EXE_PATH snapshots --json 2>$null
    if ($json) {
        $snapshots = @($json | ConvertFrom-Json | ForEach-Object { $_ })
        $resticSnapshots = $snapshots | Sort-Object time -Descending | Select-Object -First 5 | ForEach-Object {
            $snapshotTime = Get-FirstValue $_.time
            $timeStr = Format-DateTimeValue $snapshotTime
            $shortId = Get-FirstValue $_.short_id
            $longId = Get-FirstValue $_.id
            $snapshotId = if ($shortId) {
                $shortId.ToString()
            } elseif ($longId) {
                $longId.ToString()
            } else {
                "unknown"
            }
            $rawHostname = Get-FirstValue $_.hostname
            $snapshotHostname = if ($rawHostname) {
                Normalize-JsonString $rawHostname.ToString()
            } else {
                Normalize-JsonString $env:COMPUTERNAME
            }
            $snapshotPaths = if ($_.paths) {
                @($_.paths) | ForEach-Object {
                    if ($_ -is [string]) {
                        (Normalize-JsonString $_).TrimEnd('\')
                    } elseif ($_ -is [System.Collections.IEnumerable]) {
                        @($_) | ForEach-Object { (Normalize-JsonString $_.ToString()).TrimEnd('\') }
                    } else {
                        (Normalize-JsonString $_.ToString()).TrimEnd('\')
                    }
                }
            } else {
                @()
            }
            @{
                id       = Normalize-JsonString $snapshotId
                time     = Normalize-JsonString $timeStr
                hostname = $snapshotHostname
                paths    = Normalize-JsonString ($snapshotPaths -join ", ")
            }
        }
        $resticSnapshots = @($resticSnapshots)
    }
} catch {
    Write-Warning "Could not query Restic snapshots: $_"
}
}

# ── Build Payload ─────────────────────────────────────────────────────────────
# ── DNS client configuration ────────────────────────────────────────────────
# Which DNS servers this machine *uses* — distinct from dns_service_status,
# which is whether it *runs* the DNS role.
#
# Added Aug 2026 during the VCTCSERVER05 decommission. Retiring a domain
# controller means finding every device with its address hard-coded, and there
# was no way to answer "which servers still point at 10.0.0.5" without walking
# each one by hand. Collecting it here makes that a query rather than a task,
# and the same question recurs with every DC or resolver change.
$dnsClientServers = @()
try {
    $adapters = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.ServerAddresses -and $_.ServerAddresses.Count -gt 0 }
    foreach ($a in $adapters) {
        $dnsClientServers += @{
            interface = Normalize-JsonString $a.InterfaceAlias
            servers   = @($a.ServerAddresses | ForEach-Object { Normalize-JsonString $_ })
        }
    }
} catch {
    Write-Warning "Could not read DNS client configuration: $_"
}

$payloadObject = @{
    dns_client_servers    = @($dnsClientServers)
    os_info               = $osInfo
    uptime_seconds        = $uptimeSeconds
    cpu_usage             = $cpuUsage
    ram_usage_pct         = $ramUsedPct
    disks                 = $disks
    pending_updates       = $pendingUpdates
    last_update_installed = Normalize-JsonString $lastUpdateInstalled
    services              = @($services)
    domain_services       = $domainServices
    scheduled_tasks       = @($scheduledTasks)
    event_log_errors      = $eventLogErrors
    restic_snapshots      = @($resticSnapshots)
    restic_backup_history = $resticBackupHistory
    physical_disks        = @($physicalDisks)
}

Test-JsonArrayItems "dns_client_servers" @($dnsClientServers)
Test-JsonArrayItems "disks" @($disks)
Test-JsonArrayItems "services" @($services)
Test-JsonArrayItems "scheduled_tasks" @($scheduledTasks)
Test-JsonArrayItems "event_log_errors" @($eventLogErrors)
Test-JsonArrayItems "restic_snapshots" @($resticSnapshots)
Test-JsonArrayItems "restic_backup_history" @($resticBackupHistory)
Test-JsonArrayItems "physical_disks" @($physicalDisks)

foreach ($entry in $payloadObject.GetEnumerator()) {
    if ($entry.Key -in @("disks", "services", "scheduled_tasks", "event_log_errors", "restic_snapshots", "restic_backup_history", "physical_disks")) {
        continue
    }

    Test-JsonField $entry.Key $entry.Value
}

try {
    $payload = $payloadObject | ConvertTo-Json -Depth 5 -ErrorAction Stop
} catch {
    Write-Error "Payload serialization failed: $_"
    exit 1
}

# ── Send to API ───────────────────────────────────────────────────────────────
try {
    $response = Invoke-RestMethod -Uri $API_URL -Method POST -Body $payload -ContentType "application/json" -Headers @{ "x-api-key" = $API_KEY }
    Write-Host "Check-in successful: $($response.server_name)"
} catch {
    Write-Error "Check-in failed: $_"
    exit 1
}
