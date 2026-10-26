#!/bin/zsh
set -euo pipefail
umask 077
script_dir="${0:A:h}"
source "$script_dir/service-common.sh"
require_safe_paths || exit 1
backup_dir="${1:-}"
[[ -n "$backup_dir" && "${backup_dir:A:h}" == "${install_dir:A}/backups" && "$backup_dir" == "${backup_dir:A}" && -f "$backup_dir/transaction-ready" ]] || {
    print -u2 'Pass the exact backup directory printed by install.command.'; exit 64
}
for item in "$backup_dir" "$backup_dir"/*; do [[ ! -L "$item" ]] || exit 1; done
lock_dir="$install_dir/.install-lock"
/bin/mkdir "$lock_dir" || { print -u2 'Another installation/rollback is active.'; exit 1; }
trap '/bin/rmdir "$lock_dir" 2>/dev/null || true' EXIT
require_current_transaction "$backup_dir" || exit 1
if [[ -f "$backup_dir/installed.sha256" ]]; then
    /usr/bin/shasum -a 256 -c "$backup_dir/installed.sha256" || {
        print -u2 'Installed files changed since this backup; refusing to overwrite a later installation.'; exit 1
    }
fi
restore_backup "$backup_dir" || exit 1
print 'Previous service and files restored. Recheck its Accessibility permission before use.'
