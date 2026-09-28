# Copy this file to C:\Scripts\agent-config.ps1 and fill in the values for the server.

$API_URL = "http://YOUR-MONITOR-HOST:3000/api/it/checkin"
$API_KEY = "SERVER_SPECIFIC_API_KEY_FROM_/api/servers"

$RESTIC_ENV_PATH = "C:\Scripts\restic-env.ps1"
$RESTIC_EXE_PATH = "C:\Scripts\restic.exe"
$RESTIC_LOG_DIR = "C:\Scripts\Logs\restic"
$ENABLE_RESTIC_MONITORING = $true

$SERVICES_TO_MONITOR = @(
    "W32Time",
    "LanmanServer",
    "WinRM"
    # Add application-specific services here, e.g. "MSSQLSERVER" or "zenengine"
)

# Only tasks listed here are reported, and only reported tasks are checked by
# BKP-005 on the compliance page. A backup job missing from this list fails
# silently: the Sage 50 backup on VCTCSERVER06 failed weekly for over a month
# in 2026 because it was never added, while Restic kept passing beside it.
#
# List EVERY scheduled job whose failure would matter - application backups
# especially. Format is "Actual Task Name|Label shown in the portal".
$SCHEDULED_TASKS_TO_MONITOR = @(
    "VCTC Server Monitor Agent|VCTC Monitor Agent",
    "VCTC Restic Backup|Restic Backup"
    # Add application-specific tasks here, e.g.
    #   "Sage 50 Backup 1|Sage 50 Backup",
    #   "GFI SQL Backup|GFI SQL Backup"
)
