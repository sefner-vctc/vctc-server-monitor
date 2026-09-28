#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ROOT="${1:-$REPO_ROOT/dist/windows-server-bundle}"

mkdir -p "$BUNDLE_ROOT"

cp "$REPO_ROOT/scripts/agent.ps1" "$BUNDLE_ROOT/agent.ps1"
cp "$REPO_ROOT/scripts/restic-backup.ps1" "$BUNDLE_ROOT/restic-backup.ps1"
cp "$REPO_ROOT/scripts/install-windows-server.ps1" "$BUNDLE_ROOT/install-windows-server.ps1"
cp "$REPO_ROOT/scripts/agent-config.template.ps1" "$BUNDLE_ROOT/agent-config.template.ps1"
cp "$REPO_ROOT/scripts/restic-config.template.ps1" "$BUNDLE_ROOT/restic-config.template.ps1"
cp "$REPO_ROOT/scripts/restic-env.template.ps1" "$BUNDLE_ROOT/restic-env.template.ps1"
cp "$REPO_ROOT/docs/add-windows-server.md" "$BUNDLE_ROOT/README-add-windows-server.md"

cat > "$BUNDLE_ROOT/README.txt" <<'EOF'
VCTC Windows Server Onboarding Bundle

Contents:
- agent.ps1
- restic-backup.ps1
- install-windows-server.ps1
- agent-config.template.ps1
- restic-config.template.ps1
- restic-env.template.ps1
- README-add-windows-server.md

Next steps:
1. Copy this entire folder to the Windows server as C:\Scripts
2. Copy restic.exe into the same folder
3. Copy an existing restic-env.ps1 if reusing an existing repository, or create one from the template
4. Register the server in the monitor to get its unique API key
5. Run install-windows-server.ps1 from an elevated PowerShell session
EOF

echo "Windows onboarding bundle created at: $BUNDLE_ROOT"
