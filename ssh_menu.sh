#!/bin/bash
# ssh_menu — quick-pick SSH menu with favorites + recent-use awareness.
#
# Connections are loaded from $HOME/.ssh_menu.conf (override via SSH_MENU_CONF).
# Connection history is appended to $HOME/.ssh_menu.history (override via
# SSH_MENU_HISTORY). Each successful pick writes one "<unix_ts>|<name>" line.
#
# Lines in the config prefixed with '* ' are favorites.
#
# Selection modes: fzf (if installed) or numeric grouped menu.
# fzf flow:
#   - List order: recent (top 5) -> favorites -> rest.
#   - Markers: '*' yellow (favorite, optionally also recent),
#              '~' cyan   (recent, not a favorite),
#              '  '       (neither).
#   - Right column shows "Xm ago" / "Xh ago" / "Xd ago" for known entries.
#   - Below the list, a 6-line preview pane shows full info for the highlight.
#   - Keys: ↑/↓ move, type to filter, Enter connects, Esc cancels,
#           f toggles favorite (writes config + reloads).
# Numeric flow: favorites preamble (1..N), 'a' switches to full grouped menu,
#               each favorite row shows last-used timestamp if available.
#
# The site groups (NC / CO / WV / COS), their colors and the colored-tab
# behavior below are EXAMPLES. Edit the case statements in get_env_tag /
# site_color_for / tab_color_for to match your own environments. Navigator URLs
# are NOT hardcoded here — they come from the config as "nav <prefix> <url>"
# lines (see ssh_menu.conf.example). COS (production) entries require YES first.

# ── Colors ────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
PURPLE=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
DIM=$'\033[2m'
NC=$'\033[0m'

CONFIG_FILE="${SSH_MENU_CONF:-$HOME/.ssh_menu.conf}"
HISTORY_FILE="${SSH_MENU_HISTORY:-$HOME/.ssh_menu.history}"

# ──────────────────────────────────────────────────────────────────────────
# Helpers — environment / colors
#
# get_env_tag and tab_color_for match an entry by NAME PREFIX (e.g. "NC D2");
# site_color_for keys off the leading site word (e.g. "NC"). Simple case
# statements — add your own sites here. Navigator URLs are NOT here; they live
# in the config as "nav <prefix> <url>" lines.
# ──────────────────────────────────────────────────────────────────────────

get_env_tag() {
    case "$1" in
        "NC D2"*|"CO D"[12]*|"WV dev"*)     printf ' %s[dev]%s'  "$GREEN"  "$NC" ;;
        "NC I2"*)                           printf ' %s[int]%s'  "$BLUE"   "$NC" ;;
        "NC Q2"*|"NC Q3"*|"CO Q"*|"WV qa"*) printf ' %s[qa]%s'   "$YELLOW" "$NC" ;;
        "COS"*)                             printf ' %s[PROD]%s' "$RED"    "$NC" ;;
    esac
}

site_color_for() {
    case "$1" in
        NC)   printf '%s' "$GREEN"  ;;
        CO)   printf '%s' "$CYAN"   ;;
        WV)   printf '%s' "$BLUE"   ;;
        COS)  printf '%s' "$PURPLE" ;;
        *)    printf '%s' "$WHITE"  ;;
    esac
}

tab_color_for() {
    case "$1" in
        "NC D2"*|"CO D"[12]*|"WV dev"*)     printf '#00CC44' ;;
        "NC I2"*)                           printf '#3399FF' ;;
        "NC Q2"*|"NC Q3"*|"CO Q"*|"WV qa"*) printf '#DDAA00' ;;
        "COS"*)                             printf '#FF3344' ;;
    esac
}

# Map an entry to its Navigator URL (opened with the ^O bind in fzf mode).
# URLs are defined in the config as "nav <name-prefix> <url>" lines; the entry
# name is matched against them and the LONGEST matching prefix wins. Prints
# nothing when no prefix matches (so ^O does nothing for that host).
navigator_url_for() {
    local name="$1" line rest url prefix best_prefix="" best_url=""
    [[ -f "$CONFIG_FILE" ]] || return 0
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        [[ "$line" == "nav "* ]] || continue
        rest="${line#nav }"
        rest="${rest#"${rest%%[![:space:]]*}"}"           # ltrim after 'nav '
        url="${rest##* }"                                  # last whitespace token
        prefix="${rest% *}"                                # everything before it
        prefix="${prefix%"${prefix##*[![:space:]]}"}"      # rtrim
        [[ -z "$prefix" || -z "$url" || "$prefix" == "$rest" ]] && continue
        if [[ "$name" == "$prefix" || "$name" == "$prefix "* ]] \
           && (( ${#prefix} >= ${#best_prefix} )); then
            best_prefix="$prefix"; best_url="$url"
        fi
    done < "$CONFIG_FILE"
    [[ -n "$best_url" ]] && printf '%s' "$best_url"
}

# Open a URL in the host's default browser. Prefers wslview (WSL), falls back
# to explorer.exe (WSL), then xdg-open (Linux), then just prints it.
_open_url() {
    local url="$1"
    [[ -z "$url" ]] && return 1
    if command -v wslview >/dev/null 2>&1; then
        wslview "$url" >/dev/null 2>&1 &
    elif command -v explorer.exe >/dev/null 2>&1; then
        explorer.exe "$url" >/dev/null 2>&1 &
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    else
        printf '%s\n' "$url"
    fi
}

# Strip ANSI CSI sequences from stdin/string (for measuring visible width).
_strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Format unix-ts -> "Xs/m/h/d/w ago".
_fmt_ago() {
    local ts=$1 now delta
    now=$(date +%s)
    delta=$((now - ts))
    (( delta < 0 )) && delta=0
    if   (( delta < 60 ));        then printf '%ds ago' "$delta"
    elif (( delta < 3600 ));      then printf '%dm ago' $((delta / 60))
    elif (( delta < 86400 ));     then printf '%dh ago' $((delta / 3600))
    elif (( delta < 86400 * 7 )); then printf '%dd ago' $((delta / 86400))
    else                               printf '%dw ago' $((delta / 604800))
    fi
}

# ──────────────────────────────────────────────────────────────────────────
# Helpers — config + history I/O
# ──────────────────────────────────────────────────────────────────────────

# Load CONFIG_FILE into globals: connections / is_favorite / favorite_indices.
_load_connections() {
    connections=()
    is_favorite=()
    favorite_indices=()
    [[ ! -f "$CONFIG_FILE" ]] && return 1
    local line fav
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        [[ "$line" == "nav "* ]] && continue   # Navigator directive, not a host entry
        line="${line%"${line##*[![:space:]]}"}"
        fav=""
        if [[ "${line:0:2}" == "* " ]]; then
            fav="1"
            line="${line:2}"
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        connections+=("$line")
        is_favorite+=("$fav")
        [[ -n "$fav" ]] && favorite_indices+=($((${#connections[@]} - 1)))
    done < "$CONFIG_FILE"
}

# Load HISTORY_FILE into globals:
#   last_ts_by_name[$name]    -> most recent unix ts
#   times_used_by_name[$name] -> total appearance count
#   recent_names              -> top 5 names by ts, most recent first
_load_history() {
    declare -gA last_ts_by_name=()
    declare -gA times_used_by_name=()
    recent_names=()
    [[ ! -f "$HISTORY_FILE" ]] && return 0
    local ts name
    while IFS='|' read -r ts name; do
        [[ -z "$ts" || -z "$name" ]] && continue
        [[ ! "$ts" =~ ^[0-9]+$ ]] && continue
        times_used_by_name[$name]=$(( ${times_used_by_name[$name]:-0} + 1 ))
        if [[ -z "${last_ts_by_name[$name]:-}" ]] || (( ts > ${last_ts_by_name[$name]} )); then
            last_ts_by_name[$name]=$ts
        fi
    done < "$HISTORY_FILE"

    # Sort names by their last_ts descending, take top 5.
    local sorted
    sorted=$(for name in "${!last_ts_by_name[@]}"; do
        printf '%s\t%s\n' "${last_ts_by_name[$name]}" "$name"
    done | sort -rn | head -5)
    while IFS=$'\t' read -r ts name; do
        [[ -n "$name" ]] && recent_names+=("$name")
    done <<< "$sorted"
}

# Append a connect-event to HISTORY_FILE.
_record_connection() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    printf '%s|%s\n' "$(date +%s)" "$name" >> "$HISTORY_FILE"
}

# ──────────────────────────────────────────────────────────────────────────
# Helpers — fzf line generation, favorite toggle, preview
# ──────────────────────────────────────────────────────────────────────────

# Print one fzf input line per connection, ordered:
#   recent (top 5) -> favorites-not-in-recent -> rest.
# Marker column (2 chars): '* ' favorite, '~ ' recent-only, '  ' otherwise.
# Right column: time-ago if known.
_gen_lines() {
    _load_connections
    _load_history

    declare -A name_to_idx=()
    local i
    for i in "${!connections[@]}"; do
        local en
        en=$(printf '%s' "${connections[$i]}" | cut -d':' -f1)
        name_to_idx["$en"]=$i
    done

    declare -A printed=()
    local ordered=() rname idx entry_name tag marker ts ago_col tag_w tag_plain pad_n pad

    # Phase 1: recent
    for rname in "${recent_names[@]}"; do
        if [[ -n "${name_to_idx[$rname]:-}" ]]; then
            idx="${name_to_idx[$rname]}"
            if [[ -z "${printed[$idx]:-}" ]]; then
                ordered+=("$idx:recent")
                printed[$idx]=1
            fi
        fi
    done
    # Phase 2: favorites not yet printed
    for i in "${!connections[@]}"; do
        if [[ -n "${is_favorite[$i]}" && -z "${printed[$i]:-}" ]]; then
            ordered+=("$i:fav")
            printed[$i]=1
        fi
    done
    # Phase 3: everything else
    for i in "${!connections[@]}"; do
        if [[ -z "${printed[$i]:-}" ]]; then
            ordered+=("$i:rest")
            printed[$i]=1
        fi
    done

    local entry kind
    for entry in "${ordered[@]}"; do
        idx="${entry%:*}"
        kind="${entry#*:}"
        entry_name=$(printf '%s' "${connections[$idx]}" | cut -d':' -f1)
        tag=$(get_env_tag "$entry_name")
        case "$kind" in
            recent)
                if [[ -n "${is_favorite[$idx]}" ]]; then
                    marker="${YELLOW}* ${NC}"
                else
                    marker="${CYAN}~ ${NC}"
                fi
                ;;
            fav)
                marker="${YELLOW}* ${NC}"
                ;;
            *)
                marker="  "
                ;;
        esac
        ts="${last_ts_by_name[$entry_name]:-}"
        if [[ -n "$ts" ]]; then
            ago_col="${DIM}$(_fmt_ago "$ts")${NC}"
        else
            ago_col=""
        fi
        # Pad based on the tag's VISIBLE width (ANSI codes have zero width).
        tag_plain=$(_strip_ansi "$tag")
        tag_w=${#tag_plain}
        pad_n=$((14 - tag_w))
        (( pad_n < 1 )) && pad_n=1
        pad=$(printf '%*s' "$pad_n" '')
        printf '%s%-36s%s%s%s\n' "$marker" "$entry_name" "$tag" "$pad" "$ago_col"
    done
}

# Toggle the '* ' prefix on the config-file line whose name matches $1.
_toggle_fav_by_name() {
    local target="$1"
    [[ -z "$target" ]] && return 1
    local tmpfile
    tmpfile=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
    local toggled=0 line trimmed body was_fav name
    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ -z "$trimmed" || "${trimmed:0:1}" == "#" || "$trimmed" == "nav "* ]]; then
            printf '%s\n' "$line" >> "$tmpfile"
            continue
        fi
        body="$trimmed"
        was_fav=""
        if [[ "${body:0:2}" == "* " ]]; then
            was_fav="1"
            body="${body:2}"
            body="${body#"${body%%[![:space:]]*}"}"
        fi
        name=$(printf '%s' "$body" | cut -d':' -f1)
        if [[ "$name" == "$target" && $toggled -eq 0 ]]; then
            if [[ -n "$was_fav" ]]; then
                printf '%s\n' "$body" >> "$tmpfile"
            else
                printf '* %s\n' "$body" >> "$tmpfile"
            fi
            toggled=1
        else
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$CONFIG_FILE"
    mv "$tmpfile" "$CONFIG_FILE"
}

# Extract the entry name from a raw fzf line (with ANSI + padding + tag + ago).
_name_from_fzf_line() {
    local line="$1"
    local plain
    plain=$(_strip_ansi "$line")
    plain="${plain:2}"                            # strip 2-char marker
    plain="${plain% \[*}"                         # strip ' [tag]...'
    plain="${plain%"${plain##*[![:space:]]}"}"    # rtrim
    printf '%s' "$plain"
}

_toggle_fav_from_fzf_line() {
    local name
    name=$(_name_from_fzf_line "$1")
    [[ -z "$name" ]] && return 1
    _toggle_fav_by_name "$name"
}

# Print a multi-line preview for the currently-highlighted fzf row.
_preview_for_line() {
    local line="$1"
    local name
    name=$(_name_from_fzf_line "$line")
    [[ -z "$name" ]] && return 1

    _load_connections
    _load_history

    local found="" i
    for i in "${!connections[@]}"; do
        local en
        en=$(printf '%s' "${connections[$i]}" | cut -d':' -f1)
        if [[ "$en" == "$name" ]]; then
            found=$i
            break
        fi
    done
    if [[ -z "$found" ]]; then
        printf '(no match for %q)\n' "$name"
        return 1
    fi

    local conn="${connections[$found]}"
    local host port site tab fav_str last_str times
    host=$(printf '%s' "$conn" | cut -d':' -f2)
    port=$(printf '%s' "$conn" | cut -d':' -f3)
    site="${name%% *}"
    tab=$(tab_color_for "$name")
    [[ -z "$tab" ]] && tab="(default profile)"
    if [[ -n "${is_favorite[$found]}" ]]; then
        fav_str="${YELLOW}* favorite${NC}"
    else
        fav_str="${DIM}—${NC}"
    fi
    if [[ -n "${last_ts_by_name[$name]:-}" ]]; then
        last_str=$(_fmt_ago "${last_ts_by_name[$name]}")
    else
        last_str="${DIM}never${NC}"
    fi
    times="${times_used_by_name[$name]:-0}"

    local nav_url
    nav_url=$(navigator_url_for "$name")

    printf '  %s%s%s\n' "$(site_color_for "$site")" "$name" "$NC"
    printf '    host:        %s   port: %s\n' "$host" "$port"
    if [[ -n "$nav_url" ]]; then
        printf '    navigator:   %s%s%s\n' "$CYAN" "$nav_url" "$NC"
    fi
    printf '    status:      %s        last used: %s   times: %s\n' "$fav_str" "$last_str" "$times"
    printf '    site/tab:    %s / %s\n' "$site" "$tab"
}

# ──────────────────────────────────────────────────────────────────────────
# Helpers — numeric-mode rendering
# ──────────────────────────────────────────────────────────────────────────

print_header() {
    echo "${BLUE}================================${NC}"
    echo "${CYAN}         SSH CONNECTION MENU         ${NC}"
    echo "${BLUE}================================${NC}"
    echo "${DIM}config: ${CONFIG_FILE/#$HOME/~}${NC}"
    echo ""
}

render_favorites_screen() {
    _load_history
    clear
    print_header
    echo "${YELLOW}* Favorites (daily)${NC}"
    local n=1 idx entry_name tag ts ago_col
    for idx in "${favorite_indices[@]}"; do
        entry_name=$(printf '%s' "${connections[$idx]}" | cut -d':' -f1)
        tag=$(get_env_tag "$entry_name")
        ts="${last_ts_by_name[$entry_name]:-}"
        ago_col=""
        [[ -n "$ts" ]] && ago_col="   ${DIM}$(_fmt_ago "$ts")${NC}"
        printf '  %s%2d%s. %s%s%s\n' "$GREEN" "$n" "$NC" "$entry_name" "$tag" "$ago_col"
        n=$((n + 1))
    done
    echo ""
    echo "  ${CYAN}a${NC}. Show all ${#connections[@]} entries"
    echo "  ${RED}0${NC}. Exit  ${WHITE}(or ${YELLOW}q${WHITE}/${YELLOW}Q${WHITE})${NC}"
    echo ""
    printf '%sEnter your choice [1-%d, a, 0]: %s' "$PURPLE" "${#favorite_indices[@]}" "$NC"
}

render_full_menu() {
    clear
    print_header
    declare -a site_order=()
    declare -A site_indices=()
    declare -A site_seen=()
    local i entry_name site header_color tag star num
    for i in "${!connections[@]}"; do
        entry_name=$(printf '%s' "${connections[$i]}" | cut -d':' -f1)
        site="${entry_name%% *}"
        if [[ -z "${site_seen[$site]:-}" ]]; then
            site_seen[$site]=1
            site_order+=("$site")
        fi
        site_indices[$site]+="$i "
    done
    for site in "${site_order[@]}"; do
        header_color=$(site_color_for "$site")
        local indices=(${site_indices[$site]})
        echo "${header_color}── $site ─────────────────────────── (${#indices[@]})${NC}"
        for i in "${indices[@]}"; do
            entry_name=$(printf '%s' "${connections[$i]}" | cut -d':' -f1)
            tag=$(get_env_tag "$entry_name")
            star=""
            [[ -n "${is_favorite[$i]}" ]] && star="${YELLOW}*${NC}"
            num=$(printf '%2d' $((i + 1)))
            printf '  %s%s%s. %s%s%s\n' "$GREEN" "$num" "$NC" "$star" "$entry_name" "$tag"
        done
        echo ""
    done
    echo "  ${RED}0${NC}. Exit  ${WHITE}(or ${YELLOW}q${WHITE}/${YELLOW}Q${WHITE})${NC}"
    echo ""
    printf '%sEnter your choice [1-%d, 0]: %s' "$PURPLE" "${#connections[@]}" "$NC"
}

# ──────────────────────────────────────────────────────────────────────────
# Self-dispatch — fzf binds reach back into this script via these flags
# ──────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --gen-lines)
        _gen_lines
        exit 0
        ;;
    --toggle-fav)
        shift
        _toggle_fav_from_fzf_line "$1"
        exit 0
        ;;
    --preview-line)
        shift
        _preview_for_line "$1"
        exit 0
        ;;
    --open-nav)
        shift
        _name_from_fzf_line_arg=$(_name_from_fzf_line "$1")
        _nav_url=$(navigator_url_for "$_name_from_fzf_line_arg")
        [[ -n "$_nav_url" ]] && _open_url "$_nav_url"
        exit 0
        ;;
esac

# ──────────────────────────────────────────────────────────────────────────
# Main flow
# ──────────────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "${RED}Error: config file not found: ${YELLOW}$CONFIG_FILE${NC}" >&2
    echo "Create it with one connection per line in the format:" >&2
    echo "  ${CYAN}[* ]Name:user@host:port${NC}" >&2
    echo "Lines starting with # and blank lines are ignored. '* ' prefix marks a favorite." >&2
    exit 1
fi

# Loop: stay in the menu after each connect so the user can fire off
# multiple ssh tabs back-to-back. Exit only on explicit cancel
# (Esc in fzf / 0 / q in numeric mode).
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

while true; do
    _load_connections
    if [[ ${#connections[@]} -eq 0 ]]; then
        echo "${RED}Error: no connections found in ${YELLOW}$CONFIG_FILE${NC}" >&2
        exit 1
    fi

    selection_index=""

    if command -v fzf >/dev/null 2>&1; then
        selected=$("$SCRIPT_PATH" --gen-lines | fzf \
            --ansi \
            --prompt="SSH ${CONFIG_FILE/#$HOME/~} > " \
            --height=90% \
            --reverse \
            --header='filter / f=toggle fav / ^O=open navigator / Enter=ssh / Esc=exit menu' \
            --preview "$SCRIPT_PATH --preview-line {}" \
            --preview-window=down:6:wrap \
            --bind "f:execute-silent($SCRIPT_PATH --toggle-fav {})+reload($SCRIPT_PATH --gen-lines)" \
            --bind "ctrl-o:execute-silent($SCRIPT_PATH --open-nav {})")

        if [[ -z "$selected" ]]; then
            echo "${CYAN}Exiting menu.${NC}"
            break
        fi

        # Reload (in case 'f' toggled anything) and resolve.
        _load_connections
        declare -A name_to_index=()
        for i in "${!connections[@]}"; do
            entry_name=$(printf '%s' "${connections[$i]}" | cut -d':' -f1)
            name_to_index["$entry_name"]="$i"
        done
        chosen_name=$(_name_from_fzf_line "$selected")
        selection_index="${name_to_index[$chosen_name]:-}"
        if [[ -z "$selection_index" ]]; then
            echo "${RED}Error: could not resolve selection '$chosen_name'.${NC}" >&2
            continue
        fi
    else
        render_favorites_screen
        read -r choice
        case "$choice" in
            [qQ]|0)
                echo "${CYAN}Exiting menu.${NC}"
                break
                ;;
            [aA])
                render_full_menu
                read -r choice
                case "$choice" in
                    [qQ]|0)
                        echo "${CYAN}Exiting menu.${NC}"
                        break 2
                        ;;
                esac
                if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
                    echo "${RED}Please enter a number (or q to quit).${NC}" >&2
                    continue
                fi
                choice=$((choice - 1))
                if [[ $choice -lt 0 || $choice -ge ${#connections[@]} ]]; then
                    echo "${RED}Invalid selection.${NC}" >&2
                    continue
                fi
                selection_index="$choice"
                ;;
            *)
                if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
                    echo "${RED}Please enter a number, 'a', or 'q'.${NC}" >&2
                    continue
                fi
                if [[ $choice -lt 1 || $choice -gt ${#favorite_indices[@]} ]]; then
                    echo "${RED}Favorite [1-${#favorite_indices[@]}] expected, got '$choice'.${NC}" >&2
                    continue
                fi
                selection_index="${favorite_indices[$((choice - 1))]}"
                ;;
        esac
    fi

    # ── Resolve + connect ────────────────────────────────────────────────
    connection="${connections[$selection_index]}"
    name=$(printf '%s' "$connection" | cut -d':' -f1)
    host=$(printf '%s' "$connection" | cut -d':' -f2)
    port=$(printf '%s' "$connection" | cut -d':' -f3)

    case "$name" in
        "COS"*|"PROD"*)
            echo "${RED}!! PRODUCTION HOST: ${YELLOW}$name${NC}"
            printf '%sType YES to confirm: %s' "$RED" "$NC"
            read -r confirm
            if [[ "$confirm" != "YES" ]]; then
                echo "${CYAN}Aborted — back to menu.${NC}"
                continue
            fi
            ;;
    esac

    # Record BEFORE the ssh attempt so wt.exe-spawned tabs (which return
    # immediately) also get logged.
    _record_connection "$name"

    tab_color=$(tab_color_for "$name")
    echo "${GREEN}Connecting to ${YELLOW}$host${GREEN} on port ${YELLOW}$port${GREEN}...${NC}"

    if [[ -n "$tab_color" ]] && command -v wt.exe >/dev/null 2>&1; then
        profile_arg=()
        [[ -n "${WT_PROFILE_ID:-}" ]] && profile_arg=(--profile "$WT_PROFILE_ID")
        wt.exe -w 0 new-tab "${profile_arg[@]}" --tabColor "$tab_color" --title "$name" wsl ssh -p "$port" "$host"
    else
        ssh -p "$port" "$host"
    fi
done
