# Shared by install/verify/rollback; sourced with zsh's errexit enabled.
label="com.devonkong.sayroute.bridge"
legacy_label="com.doubao.murmur.mirror"
install_dir="${HOME}/Library/Application Support/SayRoute"
helper_path="${install_dir}/sayroute-bridge"
launch_agents_dir="${HOME}/Library/LaunchAgents"
launch_agent_path="${launch_agents_dir}/${label}.plist"
legacy_agent_path="${launch_agents_dir}/${legacy_label}.plist"
log_dir="${HOME}/Library/Logs/SayRoute"
user_id="$(/usr/bin/id -u)"
generation_path="$install_dir/.current-install-transaction"

require_safe_paths() {
    local candidate
    for candidate in "$install_dir" "$launch_agents_dir" "$log_dir" "$helper_path" "$launch_agent_path" "$legacy_agent_path" "$generation_path"; do
        [[ "$candidate" == "${candidate:A}" && ! -L "$candidate" ]] || {
            print -u2 "Refusing a symlinked installation path: $candidate"; return 1
        }
    done
}

stop_service() {
    local service_label="$1"
    if /bin/launchctl print "gui/${user_id}/${service_label}" >/dev/null 2>&1; then
        /bin/launchctl bootout "gui/${user_id}/${service_label}" || return 1
    fi
}

restore_backup() {
    local backup="$1"
    require_current_transaction "$backup" || return 1
    stop_service "$label" || return 1
    stop_service "$legacy_label" || return 1
    if [[ -f "$backup/new-helper" ]]; then
        /bin/cp -p "$backup/new-helper" "$helper_path" || return 1
    else
        /bin/rm -f "$helper_path" || return 1
    fi
    if [[ -f "$backup/new.plist" ]]; then
        /bin/cp -p "$backup/new.plist" "$launch_agent_path" || return 1
    else
        /bin/rm -f "$launch_agent_path" || return 1
    fi
    if [[ -f "$backup/legacy.plist" ]]; then
        /bin/cp -p "$backup/legacy.plist" "$legacy_agent_path" || return 1
    fi
    if [[ -f "$backup/new-active" ]]; then
        /bin/launchctl bootstrap "gui/${user_id}" "$launch_agent_path" || return 1
    fi
    if [[ -f "$backup/legacy-active" ]]; then
        /bin/launchctl bootstrap "gui/${user_id}" "$legacy_agent_path" || return 1
    fi
    # Consume the transaction only after all restoration effects succeed.
    /usr/bin/touch "$backup/rolled-back" || return 1
    if [[ -f "$backup/previous-transaction" ]]; then
        /bin/cp "$backup/previous-transaction" "$generation_path" || return 1
    else
        /bin/rm -f "$generation_path" || return 1
    fi
}

require_current_transaction() {
    local backup="$1"
    [[ -f "$backup/transaction-ready" && ! -e "$backup/rolled-back" &&
       -f "$generation_path" && "$(/bin/cat "$generation_path")" == "${backup:t}" ]] || {
        print -u2 'This backup is already restored or superseded by another installation.'
        return 1
    }
}

verify_service() {
    local health service_pid response_pid listener_pid
    service_pid="$(/bin/launchctl print "gui/${user_id}/${label}" | /usr/bin/awk '/^[[:space:]]*pid = / {print $3; exit}')" || return 1
    [[ "$service_pid" == <-> ]] || return 1
    health="$(/usr/bin/curl --fail --silent --show-error --max-time 2 http://127.0.0.1:17771/health)" || return 1
    [[ "$(/usr/bin/plutil -extract service raw -o - - <<< "$health")" == "$label" ]] || return 1
    [[ "$(/usr/bin/plutil -extract ok raw -o - - <<< "$health")" == true ]] || return 1
    [[ "$(/usr/bin/plutil -extract protocolVersion raw -o - - <<< "$health")" == 2 ]] || return 1
    [[ "$(/usr/bin/plutil -extract helperBuild raw -o - - <<< "$health")" == "$expected_build" ]] || return 1
    response_pid="$(/usr/bin/plutil -extract processID raw -o - - <<< "$health")" || return 1
    [[ "$response_pid" == "$service_pid" ]] || return 1
    listener_pid="$(/usr/sbin/lsof -nP -a -p "$service_pid" -iTCP@127.0.0.1:17771 -sTCP:LISTEN -t)" || return 1
    [[ "$listener_pid" == "$service_pid" ]] || return 1
    print -r -- "$health"
}
