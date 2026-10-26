#!/bin/zsh
set -euo pipefail
umask 077
script_dir="${0:A:h}"
source "$script_dir/service-common.sh"
source_helper="$script_dir/sayroute-bridge"
source_plist="$script_dir/${label}.plist"
expected_build="$(/usr/bin/sed -n 's/^helper_build=//p' "$script_dir/BUILD-INFO.txt")"
[[ -n "$expected_build" ]]
require_safe_paths || exit 1
/bin/mkdir -p "$install_dir" "$launch_agents_dir" "$log_dir" "$install_dir/backups"
[[ "$install_dir/backups" == "${install_dir:A}/backups" && ! -L "$install_dir/backups" ]]
lock_dir="$install_dir/.install-lock"
/bin/mkdir "$lock_dir" || { print -u2 'Another installation is active. Finish it before retrying.'; exit 1; }
backup_dir=""
transaction_started=0
finish() {
    local exit_code=$?
    trap - EXIT
    if (( exit_code != 0 && transaction_started == 1 )); then
        if restore_backup "$backup_dir"; then
            print -u2 "Installation failed; previous service/files restored. Backup: $backup_dir"
        else
            print -u2 "Installation failed and rollback needs attention. Run rollback.command with: $backup_dir"
        fi
    fi
    /bin/rmdir "$lock_dir" 2>/dev/null || true
    exit "$exit_code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
print 'Verifying package before stopping any service…'
(cd "$script_dir" && /usr/bin/shasum -a 256 -c sayroute-bridge.sha256)
/usr/bin/codesign --verify --strict "$source_helper"
/usr/bin/plutil -lint "$source_plist" >/dev/null
archs="$(/usr/bin/lipo -archs "$source_helper")"
[[ " $archs " == *" $(/usr/bin/uname -m) "* ]]
backup_dir="$(/usr/bin/mktemp -d "$install_dir/backups/$(/bin/date +%Y%m%d-%H%M%S).XXXXXX")"
[[ ! -e "$helper_path" ]] || /bin/cp -p "$helper_path" "$backup_dir/new-helper"
[[ ! -e "$launch_agent_path" ]] || /bin/cp -p "$launch_agent_path" "$backup_dir/new.plist"
[[ ! -e "$legacy_agent_path" ]] || /bin/cp -p "$legacy_agent_path" "$backup_dir/legacy.plist"
if /bin/launchctl print "gui/${user_id}/${label}" >/dev/null 2>&1; then
    [[ -f "$backup_dir/new.plist" && -f "$backup_dir/new-helper" ]] || { print -u2 'Running SayRoute service has no restorable installation.'; exit 1; }
    /usr/bin/touch "$backup_dir/new-active"
fi
if /bin/launchctl print "gui/${user_id}/${legacy_label}" >/dev/null 2>&1; then
    [[ -f "$backup_dir/legacy.plist" ]] || { print -u2 'Running legacy service has no restorable LaunchAgent.'; exit 1; }
    /usr/bin/touch "$backup_dir/legacy-active"
fi
/usr/bin/touch "$backup_dir/transaction-ready"
[[ ! -e "$generation_path" ]] || /bin/cp "$generation_path" "$backup_dir/previous-transaction"
print -r -- "${backup_dir:t}" > "$backup_dir/generation"
/bin/mv "$backup_dir/generation" "$generation_path"
transaction_started=1
stop_service "$legacy_label" || exit 1
stop_service "$label" || exit 1
# Retire the old plist so it cannot load alongside SayRoute at next login.
/bin/rm -f "$legacy_agent_path"
/usr/bin/install -m 0755 "$source_helper" "$helper_path"
/bin/cp "$source_plist" "$launch_agent_path"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${helper_path}" "$launch_agent_path"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath ${log_dir}/sayroute-bridge.log" "$launch_agent_path"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath ${log_dir}/sayroute-bridge.error.log" "$launch_agent_path"
/usr/bin/plutil -lint "$launch_agent_path" >/dev/null
/bin/chmod 0644 "$launch_agent_path"
/bin/launchctl bootstrap "gui/${user_id}" "$launch_agent_path"
health=""
for attempt in {1..20}; do
    if health="$(verify_service 2>/dev/null)"; then break; fi
    health=""
    /bin/sleep 0.25
done
[[ -n "$health" ]] || { print -u2 'New bridge identity/health not confirmed.'; exit 1; }
/usr/bin/shasum -a 256 "$helper_path" "$launch_agent_path" > "$backup_dir/installed.sha256"
transaction_started=0
print -r -- "Installed SayRoute Bridge $expected_build. Backup: $backup_dir"
print -r -- "Rollback: $script_dir/rollback.command '$backup_dir'"
print -r -- "$health"
if [[ "$(/usr/bin/plutil -extract accessibilityTrusted raw -o - - <<< "$health")" != true ]]; then
    print "Next: grant Accessibility to $helper_path in System Settings → Privacy & Security, then run verify.command."
fi
