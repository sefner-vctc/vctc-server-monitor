# Copy this file to a server-specific name such as:
#   C:\Scripts\install-gfinm.ps1
# Update the variables below, then run it from an elevated PowerShell session.

$MonitorUrl = "http://10.0.0.23:3000"
$ServerApiKey = "PASTE_SERVER_SPECIFIC_API_KEY_HERE"
$BackupSourcePath = "D:\Path\To\Protected\Data"
$ServicesToMonitor = @(
    "W32Time",
    "LanmanServer",
    "WinRM"
    # Add application-specific services here, for example:
    # "MSSQLSERVER",
    # "SQLSERVERAGENT"
)

& "C:\Scripts\install-windows-server.ps1" `
  -MonitorUrl $MonitorUrl `
  -ServerApiKey $ServerApiKey `
  -BackupSourcePath $BackupSourcePath `
  -ServicesToMonitor $ServicesToMonitor
