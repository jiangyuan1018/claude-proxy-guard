#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_built="$task_root/.build/Claude Proxy Guard.app"
task_app="$HOME/Applications/Claude Proxy Guard.app"
task_label="io.github.jiangyuan1018.claude-proxy-guard"
task_agent="$HOME/Library/LaunchAgents/$task_label.plist"
task_legacy_label="io.github.jiangyuan1018.claude-egress-guard"
task_legacy_app="$HOME/Applications/Claude Egress Guard.app"
task_domain="gui/$(id -u)"

[[ "$(uname -s)" == Darwin ]] || { echo "macOS is required." >&2; exit 1; }
for conflict in "local.claude-proxy-reminder" "$task_legacy_label"; do
    if /bin/launchctl print "$task_domain/$conflict" >/dev/null 2>&1; then
        echo "An earlier Claude guard ($conflict) is running. Quit Claude and run scripts/uninstall.sh (or stop the earlier agent) first." >&2
        exit 1
    fi
done
# ponytail: upgrades use uninstall.sh followed by install.sh; no in-place replacement of a running guard.
if [[ -e "$task_app" || -e "$task_agent" || -e "$task_legacy_app" ]]; then
    echo "Claude Proxy Guard (or an earlier version) is already installed. Quit Claude, run scripts/uninstall.sh, then install again." >&2
    exit 1
fi
[[ -d "$task_built" ]] || "$task_root/scripts/build.sh"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
/usr/bin/ditto "$task_built" "$task_app"
/usr/bin/plutil -create xml1 "$task_agent"
/usr/bin/plutil -insert Label -string "$task_label" "$task_agent"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$task_agent"
/usr/bin/plutil -insert ProgramArguments.0 -string "$task_app/Contents/MacOS/ClaudeProxyGuard" "$task_agent"
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
