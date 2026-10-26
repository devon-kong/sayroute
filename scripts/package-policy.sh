# Shared release/candidate policy. Sourced by zsh packaging entrypoints.
package_suffix=""
source_state="committed"
case "${1:-}" in
    --candidate)
        [[ -z "${RELEASE_TAG:-}" && "${CI:-}" != true ]] || { print -u2 'Candidate mode is local-only and cannot publish a release.'; exit 1; }
        package_suffix="-candidate"
        source_state="working-tree-candidate"
        ;;
    '')
        [[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
            print -u2 'Release packaging requires a clean committed tree. Use --candidate for local review artifacts.'; exit 1
        }
        ;;
    *) print -u2 'Usage: package script [--candidate]'; exit 64 ;;
esac
write_source_manifest() {
    local destination="$1" file
    git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' file; do
        [[ ! -f "$file" ]] || /usr/bin/shasum -a 256 "$file"
    done | LC_ALL=C /usr/bin/sort -u > "$destination"
}
