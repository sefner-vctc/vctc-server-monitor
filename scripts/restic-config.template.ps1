# Copy this file to C:\Scripts\restic-config.ps1 and adjust for the server.

$RESTIC_ENV_PATH = "C:\Scripts\restic-env.ps1"
$RESTIC_EXE_PATH = "C:\Scripts\restic.exe"
$RESTIC_LOG_DIR = "C:\Scripts\Logs\restic"

$BACKUP_SOURCE_PATHS = @(
    "D:\Path\To\Protected\Data"
    # Add more paths as needed, for example:
    # "D:\SQLBackups"
)

$RESTIC_KEEP_DAILY = 7
$RESTIC_KEEP_WEEKLY = 4
$RESTIC_KEEP_MONTHLY = 12
