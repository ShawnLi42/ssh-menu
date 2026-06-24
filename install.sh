#!/bin/bash
# install.sh — set up ssh_menu for the current user.
#
#   1. Symlinks ssh_menu.sh into ~/.local/bin/ssh_menu (override: BIN_DIR).
#   2. Seeds ~/.ssh_menu.conf from the example if you don't have one yet.
#   3. Checks dependencies and offers to install fzf (the nice UI) if missing.
#
# Nothing here runs sudo without asking first. fzf is optional — without it
# ssh_menu falls back to a plain numeric menu.

set -euo pipefail

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'
CYAN=$'\033[0;36m';  DIM=$'\033[2m';      NC=$'\033[0m'

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SRC_DIR/ssh_menu.sh"
EXAMPLE="$SRC_DIR/ssh_menu.conf.example"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LINK="$BIN_DIR/ssh_menu.sh"
CONF="${SSH_MENU_CONF:-$HOME/.ssh_menu.conf}"

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n'  "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n'  "$YELLOW" "$NC" "$*"; }

# ── 1. Symlink the script onto PATH ──────────────────────────────────────
mkdir -p "$BIN_DIR"
ln -sf "$SCRIPT" "$LINK"
chmod +x "$SCRIPT"
ok "Linked $LINK -> $SCRIPT"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH. Add this to your shell rc:"
       say  "    ${CYAN}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}" ;;
esac

# ── 2. Seed the config ───────────────────────────────────────────────────
if [[ -e "$CONF" ]]; then
    ok "Config already exists at $CONF (left untouched)"
else
    cp "$EXAMPLE" "$CONF"
    ok "Seeded $CONF from the example — edit it with your hosts"
fi

# ── 3. Dependency check ──────────────────────────────────────────────────
say ""
say "${DIM}Checking dependencies...${NC}"

for req in ssh sed sort cut mktemp; do
    if ! command -v "$req" >/dev/null 2>&1; then
        warn "Missing required tool: $req (install your system's coreutils/openssh)"
    fi
done

# Detect the platform package manager for an fzf install hint/offer.
pm_install_cmd() {
    if   command -v brew    >/dev/null 2>&1; then echo "brew install fzf"
    elif command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y fzf"
    elif command -v dnf     >/dev/null 2>&1; then echo "sudo dnf install -y fzf"
    elif command -v pacman  >/dev/null 2>&1; then echo "sudo pacman -S --noconfirm fzf"
    elif command -v zypper  >/dev/null 2>&1; then echo "sudo zypper install -y fzf"
    fi
}

if command -v fzf >/dev/null 2>&1; then
    ok "fzf found — the fuzzy UI is enabled"
else
    warn "fzf not found — ssh_menu will use the basic numeric menu instead."
    cmd=$(pm_install_cmd || true)
    if [[ -n "${cmd:-}" ]]; then
        printf 'Install fzf now with "%s%s%s"? [y/N] ' "$CYAN" "$cmd" "$NC"
        read -r reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            eval "$cmd" && ok "fzf installed" || warn "fzf install failed — run it manually later"
        else
            say "  Skipped. Install later with: ${CYAN}$cmd${NC}"
        fi
    else
        say "  Install fzf from your package manager or https://github.com/junegunn/fzf"
    fi
fi

say ""
ok "Done. Run ${CYAN}ssh_menu.sh${NC} to start (or ${CYAN}$LINK${NC} if PATH isn't set up yet)."
warn "Before connecting, configure your hosts in ${CYAN}$CONF${NC} — see ${CYAN}$EXAMPLE${NC} for the format."
