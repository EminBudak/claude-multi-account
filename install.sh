#!/bin/bash
# claude-multi-account installer (macOS).
#
# Links the two commands from this repository into a directory on your PATH:
#
#   claude-multi          run several Claude Desktop accounts side by side
#   claude-sessions-sync  keep the Claude Code session list identical everywhere
#
#   ./install.sh              install (symlinks, nothing is copied)
#   ./install.sh --force      replace files that are in the way
#   ./install.sh --uninstall  remove the symlinks this installer created
#
# The commands are symlinked, not copied: `git pull` in this repository updates
# them in place. The installer never calls sudo, never installs a background
# job and never launches Claude. It writes in exactly two places: the link
# directory (the symlinks, and the directory itself when it has to be created),
# and this repository's own bin/, where it sets the executable bit on the two
# commands and changes nothing else.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$REPO/bin"
TOOLS="claude-multi claude-sessions-sync"

APP_PATH="/Applications/Claude.app"
SYNC_LABEL="io.github.claude-multi.sync"

MODE="install"
FORCE=0

# ---------------------------------------------------------------- output ----
if [ -t 1 ]; then B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'; else B=""; DIM=""; R=""; fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$R"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
usage: ./install.sh [--force] [--uninstall] [--help]

  (no flags)    link claude-multi and claude-sessions-sync onto your PATH
  --force       replace an unrelated file already sitting at the target name
  --uninstall   remove only the symlinks that point into this repository
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) MODE="uninstall" ;;
        --force)     FORCE=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

# ----------------------------------------------------------------- helpers --
on_path() { case ":${PATH:-}:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

# BSD readlink has no -f: resolve one level and make the result absolute.
link_target() {
    local link="$1" target
    target="$(readlink "$link" 2>/dev/null || true)"
    [ -n "$target" ] || { echo ""; return; }
    case "$target" in
        /*) echo "$target" ;;
        *)  echo "$(cd "$(dirname "$link")" && pwd)/$target" ;;
    esac
}

points_into_repo() { # link -> 0 when it resolves into this repo's bin dir
    local t
    t="$(link_target "$1")"
    [ -n "$t" ] || return 1
    case "$t" in "$SRC_DIR"/*) return 0 ;; *) return 1 ;; esac
}

# Every directory worth looking in when removing old symlinks.
candidate_dirs() {
    printf '%s\n' /usr/local/bin "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin
    printf '%s\n' "${PATH:-}" | tr ':' '\n'
}

shell_rc() {
    case "$(basename "${SHELL:-/bin/zsh}")" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bash_profile" ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

path_line() { # the exact line to add, in the syntax of the user's shell
    local dir="$1"
    case "$(basename "${SHELL:-/bin/zsh}")" in
        fish) printf 'fish_add_path %s\n' "$dir" ;;
        *)    printf 'export PATH="%s:$PATH"\n' "$dir" ;;
    esac
}

# ------------------------------------------------------------- uninstall ----
if [ "$MODE" = "uninstall" ]; then
    # Say this BEFORE the links go, while `claude-sessions-sync` still answers
    # on the PATH. Afterwards the only way to reach it is the in-repo path.
    if [ -f "$HOME/Library/LaunchAgents/$SYNC_LABEL.plist" ]; then
        warn "the background sync job is still installed."
        say  "  Remove it FIRST, while the command is still on your PATH:"
        say  ""
        say  "      claude-sessions-sync --uninstall"
        say  ""
        say  "  (Carrying on: the same command is printed with its full path below.)"
        say  ""
    fi
    step "Removing symlinks that point into $SRC_DIR"
    removed=0
    seen=""
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        case " $seen " in *" $dir "*) continue ;; esac
        seen="$seen $dir"
        [ -d "$dir" ] || continue
        for tool in $TOOLS; do
            link="$dir/$tool"
            [ -L "$link" ] || continue
            if points_into_repo "$link"; then
                if rm -f "$link" 2>/dev/null; then
                    say "  removed $link"
                    removed=$((removed + 1))
                else
                    warn "could not remove $link (no write permission on $dir)"
                fi
            else
                note "left alone: $link (does not point into this repository)"
            fi
        done
    done <<EOF
$(candidate_dirs)
EOF
    [ "$removed" -gt 0 ] || say "  nothing to remove"

    say ""
    step "Left in place on purpose"
    say "  The installer does not delete your data. To finish by hand - the same"
    say "  list as \"How do I undo everything?\" in the README:"
    say ""
    # The full path, not the bare command: the symlinks were removed a few
    # lines ago, so `claude-sessions-sync` is no longer on the PATH and the
    # bare name would fail for exactly the person following this instruction.
    say "    $SRC_DIR/claude-sessions-sync --uninstall  # the background job ($SYNC_LABEL)"
    # Kept line for line identical to the README's undo block. The launcher
    # lines cover every place claude-multi can have written one: /Applications,
    # ~/Applications when /Applications was not writable, and wherever
    # CLAUDE_MULTI_LAUNCHER_DIR pointed (the :? refuses to run when it is
    # unset, instead of globbing at the root of the disk).
    cat <<'UNDO'
    rm -rf ~/.claude-profiles                     # profiles: logins, settings AND their session lists
    rm -rf "/Applications/Claude - "*.app         # the launchers
    rm -rf ~/Applications/"Claude - "*.app        # ...if /Applications was not writable
    rm -rf "${CLAUDE_MULTI_LAUNCHER_DIR:?}/Claude - "*.app  # ...if you set CLAUDE_MULTI_LAUNCHER_DIR
    rm -rf ~/.claude/backups/claude-sessions-*    # the automatic backups
    rm -f  ~/.claude/logs/claude-sessions-sync.log
    rm -f  ~/.claude/logs/claude-sessions-sync.err.log
    rm -f  ~/.claude/logs/claude-sessions-sync.lock
UNDO
    say ""
    say "  Removing a profile signs that account out of its own Claude instance."
    say "  The backups and the logs hold session titles and working-directory"
    say "  paths. Your conversation transcripts live in ~/.claude/projects and are"
    say "  untouched by all of the above."
    say ""
    say "  Before removing ~/.claude-profiles: each profile keeps its own copy of the"
    say "  session list. If the sync has been running, those entries are in your"
    say "  main profile too. If a profile was never synced, its sidebar entries go"
    say "  with it. Run: $SRC_DIR/claude-sessions-sync --apply   first if unsure."
    exit 0
fi

# ---------------------------------------------------------- prerequisites ----
step "Checking this machine"

[ "$(uname -s)" = "Darwin" ] || die "this tool is macOS only (it drives Claude Desktop,
       Electron user-data directories and launchd). Detected: $(uname -s)."
say "  macOS $(sw_vers -productVersion 2>/dev/null || echo "?")"

missing=0

if [ -d "$APP_PATH" ]; then
    say "  Claude Desktop found at $APP_PATH"
elif [ -d "$HOME/Applications/Claude.app" ]; then
    warn "Claude Desktop is in ~/Applications, not $APP_PATH."
    say  "  Move it to /Applications, otherwise the profile launchers will not find it."
else
    warn "Claude Desktop not found at $APP_PATH."
    say  "  Install it from https://claude.ai/download and re-run this installer."
    say  "  (Installation continues; the commands will just have nothing to launch.)"
fi

# Probe, do not stat: without the Command Line Tools /usr/bin/python3 still
# exists and is executable, but it is a stub that only offers to install them.
if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
    say "  python3 found at $(command -v python3)"
elif command -v python3 >/dev/null 2>&1; then
    warn "python3 is present but does not run - it is the Command Line Tools stub."
    say  "  Install them:  xcode-select --install"
    missing=1
else
    warn "python3 not found. The sync engine is a stdlib-only Python 3 script."
    say  "  Install Apple's command line tools:  xcode-select --install"
    missing=1
fi

for tool in $TOOLS; do
    [ -f "$SRC_DIR/$tool" ] || { warn "missing file: $SRC_DIR/$tool"; missing=1; }
done

[ "$missing" -eq 0 ] || die "cannot continue until the items above are fixed."

# -------------------------------------------------------- link directory ----
step "Choosing a directory on your PATH"

TARGET_DIR=""
if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    TARGET_DIR="/usr/local/bin"
elif [ -d /usr/local/bin ]; then
    note "/usr/local/bin exists but is not writable by you (that would need sudo)."
fi

if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR="$HOME/.local/bin"
    mkdir -p "$TARGET_DIR"
fi
say "  using $TARGET_DIR"

# ----------------------------------------------------------------- link -----
step "Linking commands"

chmod +x "$SRC_DIR"/* 2>/dev/null || true

for tool in $TOOLS; do
    src="$SRC_DIR/$tool"
    dst="$TARGET_DIR/$tool"
    # A real directory in the way is never something to delete for the user:
    # `rm -f` refuses it and, under `set -e`, would abort the installer half
    # way through with only rm's own message - and `rm -rf` on a path built
    # from TARGET_DIR is not a risk worth taking. Say so and stop cleanly.
    if [ -d "$dst" ] && [ ! -L "$dst" ]; then
        die "$dst is a directory, not a command.
       Remove or rename it yourself, then re-run this installer."
    fi
    if [ -L "$dst" ]; then
        if points_into_repo "$dst"; then
            rm -f "$dst" || die "could not remove the old symlink $dst"
        elif [ "$FORCE" -eq 1 ]; then
            note "replacing existing symlink $dst -> $(link_target "$dst")"
            rm -f "$dst" || die "could not remove $dst"
        else
            die "$dst already exists and points somewhere else:
         $(link_target "$dst")
       Remove it yourself, or re-run with --force."
        fi
    elif [ -e "$dst" ]; then
        if [ "$FORCE" -eq 1 ]; then
            note "replacing existing file $dst"
            rm -f "$dst" || die "could not remove $dst"
        else
            die "$dst already exists and is not a symlink.
       Remove it yourself, or re-run with --force."
        fi
    fi
    ln -s "$src" "$dst" || die "could not link $dst -> $src"
    say "  $dst -> $src"
done

# ------------------------------------------------------------ PATH check ----
if on_path "$TARGET_DIR"; then
    resolved="$(command -v claude-multi 2>/dev/null || true)"
    if [ -n "$resolved" ] && [ "$resolved" != "$TARGET_DIR/claude-multi" ]; then
        warn "another claude-multi comes first on your PATH: $resolved"
        say  "  Fix the order, or call $TARGET_DIR/claude-multi directly."
    fi
else
    rc="$(shell_rc)"
    say ""
    step "$TARGET_DIR is not on your PATH"
    say "  Add this line to $rc, then open a new terminal:"
    say ""
    say "    $(path_line "$TARGET_DIR")"
    say ""
fi

# ----------------------------------------------------------- next steps -----
say ""
step "Installed. Next steps:"
say ""
say "    claude-multi doctor"
say "    claude-multi setup work@example.com personal@example.com"
say ""
note "Name each profile after the account that will sign in to it, so"
note "'claude-multi list' tells you which window is which."
note "Run 'setup' from Terminal.app: it quits every Claude Desktop window,"
note "so from a Claude Code session inside the app it would kill itself."
note "Sign-in note: a brand new profile must be the only running Claude"
note "instance while you sign in, because macOS hands the claude:// callback"
note "to whichever instance started first. One-time cost per profile."
note "Your MCP config (and any API keys in it) is copied into a new profile"
note "only if you ask: claude-multi asks once per profile, and defaults to no."
say ""
say "Uninstall later with: $REPO/install.sh --uninstall"
