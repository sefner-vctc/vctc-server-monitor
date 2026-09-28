#!/usr/bin/env bash
# VCTC Linux Agent Configuration
# Copy to /etc/vctc-agent/config.sh and fill in values.
# Permissions: chmod 600 /etc/vctc-agent/config.sh
#
# Install agent:
#   cp agent-linux.sh /usr/local/bin/vctc-agent.sh
#   chmod 755 /usr/local/bin/vctc-agent.sh
#
# Cron entry (runs every 30 minutes as root):
#   */30 * * * * root /usr/local/bin/vctc-agent.sh >> /var/log/vctc-agent.log 2>&1

# ---------------------------------------------------------------------------
# Required: API endpoint (no trailing slash)
# ---------------------------------------------------------------------------
API_URL="https://your-server-monitor.example.com/api/checkin"

# ---------------------------------------------------------------------------
# Required: API key for authentication (x-api-key header)
# ---------------------------------------------------------------------------
API_KEY="your-api-key-here"

# ---------------------------------------------------------------------------
# Optional: systemd service names to monitor (exact unit names without .service)
# Leave empty or commented out to skip service monitoring.
#
# Example:
# SERVICES_TO_MONITOR=(
#     "nginx"
#     "postgresql"
#     "ssh"
# )
# ---------------------------------------------------------------------------
SERVICES_TO_MONITOR=()
