#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
source "$script_dir/service-common.sh"
expected_build="$(/usr/bin/sed -n 's/^helper_build=//p' "$script_dir/BUILD-INFO.txt")"
require_safe_paths || exit 1
[[ -x "$helper_path" && -f "$launch_agent_path" ]]
/usr/bin/codesign --verify --strict "$helper_path"
/usr/bin/plutil -lint "$launch_agent_path"
health="$(verify_service)" || { print -u2 'Expected SayRoute Bridge is not healthy; rerun install.command or inspect ~/Library/Logs/SayRoute/.'; exit 1; }
print -r -- "$health"
if [[ "$(/usr/bin/plutil -extract accessibilityTrusted raw -o - - <<< "$health")" != true ]]; then
    print -u2 "Grant Accessibility to $helper_path, then rerun this verification."
    exit 2
fi
print 'SayRoute Bridge identity, version, listener and Accessibility verified.'
