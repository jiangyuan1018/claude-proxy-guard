#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_built="$task_root/.build/Claude Egress Guard.app"
task_app="$HOME/Applications/Claude Egress Guard.app"
task_label="io.github.jiangyuan1018.claude-egress-guard"
task_agent="$HOME/Library/LaunchAgents/$task_label.plist"
task_domain="gui/$(id -u)"

[[ "$(uname -s)" == Darwin ]] || { echo "macOS is required." >&2; exit 1; }
if /bin/launchctl print "$task_domain/local.claude-proxy-reminder" >/dev/null 2>&1; then
    echo "An earlier Claude guard is running. Stop it and remove its login agent before installing this one." >&2
    exit 1
fi
# shortcut: upgrades use uninstall.sh followed by install.sh; no in-place replacement of a running guard.
if [[ -e "$task_app" || -e "$task_agent" ]]; then
    echo "This version is already installed. Quit Claude, run scripts/uninstall.sh, then install again." >&2
    exit 1
fi
[[ -d "$task_built" ]] || "$task_root/scripts/build.sh"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
/usr/bin/ditto "$task_built" "$task_app"
/usr/bin/plutil -create xml1 "$task_agent"
/usr/bin/plutil -insert Label -string "$task_label" "$task_agent"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$task_agent"
/usr/bin/plutil -insert ProgramArguments.0 -string "$task_app/Contents/MacOS/ClaudeEgressGuard" "$task_agent"
/usr/bin/plutil -insert ProgramArguments.1 -json '"--background"' "$task_agent"
/usr/bin/plutil -insert RunAtLoad -bool true "$task_agent"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$task_agent"
/usr/bin/plutil -insert ProcessType -string Interactive "$task_agent"
/usr/bin/plutil -insert StandardOutPath -string /dev/null "$task_agent"
/usr/bin/plutil -insert StandardErrorPath -string /dev/null "$task_agent"
chmod 644 "$task_agent"
/usr/bin/plutil -lint "$task_agent"
[[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$task_agent")" == '--background' ]]
/bin/launchctl bootstrap "$task_domain" "$task_agent"
printf 'Installed: %s\n' "$task_app"
