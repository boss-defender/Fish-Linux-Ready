#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  fish-look-cool.sh
#  One command: update system → install fish → make it default → cool prompt.
#
#  Supported (auto-detected):
#    apt     → Ubuntu, Debian, Linux Mint, Pop!_OS, Zorin OS, Kali Linux
#    dnf     → Fedora
#    pacman  → Arch Linux, Manjaro, Omarchy (and Arch-based derivatives)
#
#  OMARCHY SPECIAL HANDLING:
#    Omarchy's boot chain requires Bash as the login shell. We keep Bash as the
#    login shell and configure the terminal emulator to launch Fish. This is
#    the officially supported pattern (see omarchy-fish package).
#
#  Usage:  ./fish-look-cool.sh
#          ./fish-look-cool.sh --prompt-only   (refresh the prompt only)
#          ./fish-look-cool.sh --no-update     (skip the full system upgrade)
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

# ── pretty output ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s ✔ %s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s !  %s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s ✘  %s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "Something went wrong near line $LINENO. Setup aborted."' ERR

KEEPALIVE_PID=""
STAGING_DIR=""
cleanup() {
    if [[ -n "$KEEPALIVE_PID" ]]; then
        kill "$KEEPALIVE_PID" 2>/dev/null || true
    fi
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
}
trap cleanup EXIT

# ── options ───────────────────────────────────────────────────────────────────
PROMPT_ONLY=0
UPDATE_SYSTEM=1
while (($#)); do
    case "$1" in
        --prompt-only|-p) PROMPT_ONLY=1 ;;
        --no-update)      UPDATE_SYSTEM=0 ;;
        -h|--help)
            printf 'Usage: %s [--prompt-only] [--no-update]\n\n' "${0##*/}"
            printf '  (no option)     update the system, install fish, set it as default, install prompt\n'
            printf '  --no-update     skip the system-wide update/upgrade\n'
            printf '  --prompt-only   install only the custom prompt and Foot reflow fix\n'
            exit 0
            ;;
        *) die "Unknown option: $1  (try --help)" ;;
    esac
    shift
done

# ── preflight ─────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Linux" ]] || die "This script only supports Linux."

if [[ $EUID -eq 0 ]]; then
    SUDO=""
    TARGET_USER="${SUDO_USER:-root}"      # if run via sudo, configure the real user
else
    if [[ $PROMPT_ONLY -eq 0 ]]; then
        command -v sudo >/dev/null 2>&1 || die "sudo is required. Install it or run this script as root."
    fi
    SUDO="sudo"
    TARGET_USER="$(id -un)"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not find the home directory of '$TARGET_USER'."

run() { $SUDO "$@"; }

# Omarchy 4+ ships an ALPM hook that aborts a direct `pacman -Syu` and asks for
# `omarchy update` instead (installing single packages is still allowed).
IS_OMARCHY=0
if [[ -x /usr/bin/omarchy-update-pacman-guard || -d /usr/share/omarchy ]] \
    || command -v omarchy-update >/dev/null 2>&1; then
    IS_OMARCHY=1
fi

# ── detect OS / package manager ───────────────────────────────────────────────
detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release — unable to detect your distro."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
    local like=" ${ID_LIKE:-} "
    PM=""

    case "$OS_ID" in
        ubuntu|debian|pop|linuxmint|zorin|kali|raspbian|elementary|neon) PM="apt" ;;
        fedora|nobara)                                                   PM="dnf" ;;
        arch|manjaro|endeavouros|garuda|artix|cachyos|arcolinux)         PM="pacman" ;;
    esac

    # Support derivatives by their declared family, but never guess from installed tools.
    if [[ -z "$PM" ]]; then
        case "$like" in
            *" debian "*|*" ubuntu "*) PM="apt" ;;
            *" fedora "*|*" rhel "*)   PM="dnf" ;;
            *" arch "*)                 PM="pacman" ;;
        esac
    fi

    [[ -n "$PM" ]] || die "Unsupported distro: $OS_NAME"

    # Image-based systems (Silverblue, Kinoite, Bazzite, SteamOS…) have a
    # read-only /usr, so a normal package install cannot work there.
    if [[ -e /run/ostree-booted || "${VARIANT_ID:-}" == "steamdeck" || "$OS_ID" == "steamos" ]]; then
        die "$OS_NAME is an immutable/image-based system; install fish with its own tools (rpm-ostree, a toolbox…) instead."
    fi
    case "$PM" in
        apt)    command -v apt-get >/dev/null 2>&1 || die "This Debian-family distro does not provide apt-get." ;;
        dnf)    command -v dnf >/dev/null 2>&1 || die "This Fedora-family distro does not provide dnf." ;;
        pacman) command -v pacman >/dev/null 2>&1 || die "This Arch-family distro does not provide pacman." ;;
    esac
}

# ── keep sudo alive so long upgrades don't ask for the password twice ────────
start_sudo_keepalive() {
    [[ -n "$SUDO" ]] || return 0
    info "Asking for your sudo password once…"
    sudo -v || die "sudo authentication failed."
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    KEEPALIVE_PID=$!
}

# ── update + upgrade ──────────────────────────────────────────────────────────
update_system() {
    [[ $UPDATE_SYSTEM -eq 1 ]] || { info "Skipping system update (--no-update)."; return 0; }
    case "$PM" in
        apt)
            run env DEBIAN_FRONTEND=noninteractive apt-get update
            run env DEBIAN_FRONTEND=noninteractive apt-get -y \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold upgrade
            ;;
        dnf)
            run dnf -y upgrade --refresh
            ;;
        pacman)
            if [[ $IS_OMARCHY -eq 1 && -x /usr/bin/omarchy-update-pacman-guard ]]; then
                if [[ $EUID -ne 0 ]] && command -v omarchy-update >/dev/null 2>&1; then
                    # Omarchy's supported path: snapshot, packages, migrations.
                    # It revokes sudo when it finishes, so re-authorise after.
                    info "Omarchy detected: updating through 'omarchy update' (it may ask for your password again)…"
                    omarchy-update -y
                    sudo -v || die "sudo authentication failed."
                else
                    warn "Omarchy detected while running as root: skipping the system update."
                    warn "Run  omarchy update  as your normal user afterwards."
                fi
            else
                run pacman -Syu --noconfirm
            fi
            ;;
    esac
}

# ── install fish ──────────────────────────────────────────────────────────────
install_fish() {
    case "$PM" in
        apt)    run env DEBIAN_FRONTEND=noninteractive apt-get install -y fish ;;
        dnf)
            run dnf install -y fish
            # On Fedora < 39, chsh lives in util-linux-user.  On newer Fedora
            # and RHEL 9+, it is part of util-linux itself, but installing the
            # subpackage is harmless (it is either present or a no-op).
            run dnf install -y util-linux-user 2>/dev/null || true
            ;;
        pacman) run pacman -S --noconfirm --needed fish ;;
    esac
    FISH_PATH="$(command -v fish)" || die "fish was not found after installation."
}

# ── make fish the default shell (Omarchy-safe) ────────────────────────────────
set_default_shell() {
    if [[ $IS_OMARCHY -eq 1 ]]; then
        # ── Omarchy: keep bash as login shell, launch fish from the terminal ──
        # The officially supported pattern is to configure the terminal
        # emulator to launch Fish, NOT to change the login shell.
        # See: https://github.com/omacom/omarchy/discussions/2495
        local ghostty_conf="$TARGET_HOME/.config/ghostty/config"
        local alacritty_conf="$TARGET_HOME/.config/alacritty/alacritty.toml"
        local foot_conf="$TARGET_HOME/.config/foot/foot.ini"

        # Ghostty (Omarchy's default terminal as of 3.2.0)
        if command -v ghostty >/dev/null 2>&1 || [[ -d "$TARGET_HOME/.config/ghostty" ]]; then
            mkdir -p "$(dirname "$ghostty_conf")"
            if ! grep -q "^command = " "$ghostty_conf" 2>/dev/null; then
                echo "command = /usr/bin/fish" >> "$ghostty_conf"
                ok "Ghostty configured to launch fish"
            else
                ok "Ghostty already configured to launch a custom shell"
            fi
        fi

        # Alacritty (fallback for older Omarchy)
        if command -v alacritty >/dev/null 2>&1 || [[ -d "$TARGET_HOME/.config/alacritty" ]]; then
            mkdir -p "$(dirname "$alacritty_conf")"
            if ! grep -q "program = " "$alacritty_conf" 2>/dev/null; then
                {
                    echo ""
                    echo "[terminal.shell]"
                    echo "program = \"/usr/bin/fish\""
                } >> "$alacritty_conf"
                ok "Alacritty configured to launch fish"
            fi
        fi

        # Foot (Omarchy 4+)
        if command -v foot >/dev/null 2>&1 || [[ -d "$TARGET_HOME/.config/foot" ]]; then
            mkdir -p "$(dirname "$foot_conf")"
            if ! grep -q "^shell=" "$foot_conf" 2>/dev/null; then
                echo "shell=/usr/bin/fish" >> "$foot_conf"
                ok "Foot configured to launch fish"
            fi
        fi

        # Also install the bash wrapper for completeness (e.g. SSH sessions
        # that don't go through the terminal emulator).
        local bashrc="$TARGET_HOME/.bashrc"
        local wrapper_marker="# fish-look-cool: exec fish for interactive sessions"
        if ! grep -qF "$wrapper_marker" "$bashrc" 2>/dev/null; then
            {
                echo ""
                echo "$wrapper_marker"
                echo "# Only exec fish for interactive shells; non-interactive shells"
                echo "# (SSH commands, scripts) must remain bash-compatible."
                echo 'if [[ $- == *i* ]]; then'
                echo "    exec \"$FISH_PATH\" --login"
                echo "fi"
            } >> "$bashrc"
            ok "Bash wrapper installed (fallback for SSH / non-GUI sessions)"
        fi

        # Ensure fish is in /etc/shells for completeness (ssh etc.)
        if ! grep -qx "$FISH_PATH" /etc/shells 2>/dev/null; then
            echo "$FISH_PATH" | run tee -a /etc/shells >/dev/null
        fi

    else
        # ── Non-Omarchy: standard chsh approach ──────────────────────────────
        if ! grep -qx "$FISH_PATH" /etc/shells 2>/dev/null; then
            echo "$FISH_PATH" | run tee -a /etc/shells >/dev/null
        fi

        local current
        current="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
        if [[ "$current" == "$FISH_PATH" ]]; then
            ok "fish is already the default shell for $TARGET_USER"
            return 0
        fi

        if ! run chsh -s "$FISH_PATH" "$TARGET_USER" 2>/dev/null; then
            run usermod -s "$FISH_PATH" "$TARGET_USER"
        fi
        ok "Default shell for $TARGET_USER set to $FISH_PATH"
    fi
}

# ── write the cool prompt ─────────────────────────────────────────────────────
backup_if_exists() {
    local f="$1" new="${2:-}" backup
    # Skip the backup when the file is already identical to what we install.
    if [[ -n "$new" && -f "$f" ]] && cmp -s -- "$f" "$new"; then
        return 0
    fi
    if [[ -f "$f" ]]; then
        backup="$(mktemp "${f}.bak.XXXXXX")"
        cp -p -- "$f" "$backup"
        warn "Existing $(basename "$f") backed up to $backup"
    fi
}

install_prompt() {
    local config_root="$TARGET_HOME/.config"
    local fish_config="$config_root/fish"
    local func_dir="$fish_config/functions"
    local conf_dir="$fish_config/conf.d"
    local prompt_file="$func_dir/fish_prompt.fish"
    local right_file="$func_dir/fish_right_prompt.fish"
    local reflow_file="$conf_dir/fish-look-cool.fish"
    local target_group

    # On Omarchy, if the official omarchy-fish package is installed, skip
    # the custom prompt to avoid conflicts with Starship and its functions.
    if [[ $IS_OMARCHY -eq 1 ]] && pacman -Q omarchy-fish >/dev/null 2>&1; then
        warn "omarchy-fish is installed. Its Starship prompt will replace this one."
        warn "Skipping custom prompt installation. Remove omarchy-fish first if"
        warn "you want to use fish-look-cool's prompt."
        return 0
    fi

    mkdir -p "$func_dir" "$conf_dir"
    if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
        target_group="$(id -gn "$TARGET_USER")"
        # Correct only these directory entries; leave their contents and the
        # rest of the user's Fish configuration tree untouched.
        chown "$TARGET_USER:$target_group" "$config_root" "$fish_config" "$func_dir" "$conf_dir"
    fi
    STAGING_DIR="$(mktemp -d "$func_dir/.fish-look-cool.XXXXXX")"
    local prompt_tmp="$STAGING_DIR/fish_prompt.fish"
    local reflow_tmp="$STAGING_DIR/fish-look-cool.fish"

    # ── left prompt ──────────────────────────────────────────────────────────
    cat > "$prompt_tmp" <<'FISH_PROMPT'
# fish-look-cool · fish_prompt
#
#   ╭─ user@host  ~/projects/blog  on main ●1 ✚2 …3  ✘ 127
#   │
#   ╰─❯
#
#  • a blank line separates a command's output from the next prompt
#  • the arrow turns red (and the exit code shows) when a command fails
#  • user@host only appears over SSH or as root
#
# Colours are Tokyo-Night-ish hex values; change them to taste.

# ── git styling (used by the built-in fish_git_prompt) ───────────────────────
set -g __fish_git_prompt_show_informative_status 1
set -g __fish_git_prompt_char_stateseparator ' '
set -g __fish_git_prompt_color_branch bb9af7 --bold
set -g __fish_git_prompt_color_cleanstate 9ece6a
set -g __fish_git_prompt_color_stagedstate 9ece6a
set -g __fish_git_prompt_color_dirtystate e0af68
set -g __fish_git_prompt_color_untrackedfiles 7dcfff
set -g __fish_git_prompt_color_invalidstate f7768e
set -g __fish_git_prompt_color_upstream 7aa2f7

# ── blank line between commands ──────────────────────────────────────────────
# After every command we remember "leave a gap"; `clear` / `reset` forget it so
# the prompt doesn't start with an empty line at the top of a fresh screen.
function __flc_postexec --on-event fish_postexec
    if string match -qr '^\s*(clear|reset)\s*$' -- "$argv[1]"
        set -e __flc_gap
    else
        set -g __flc_gap 1
    end
end

# ── readable path: ~/a/b/c, or …/x/y/z when it is deeper than 3 levels ───────
function __flc_pwd
    set -l p $PWD
    if test "$p" = "$HOME"
        echo '~'
        return
    end
    if string match -q -- "$HOME/*" "$p"
        set p '~'(string sub -s (math (string length -- "$HOME") + 1) -- "$p")
    end
    set -l parts (string split / -- $p)
    if test (count $parts) -gt 4
        set p '…/'(string join / $parts[-3..-1])
    end
    echo $p
end

function fish_prompt
    set -l last_status $status

    # the gap
    set -q __flc_gap; and echo

    # ╭─ line 1
    set_color 565f89
    echo -n '╭─ '

    # user@host — only over SSH or as root
    if set -q SSH_CONNECTION; or test "$USER" = root
        if test "$USER" = root
            set_color --bold f7768e
        else
            set_color --bold 7dcfff
        end
        echo -n "$USER@"(prompt_hostname)' '
    end

    # directory
    set_color --bold 7aa2f7
    echo -n (__flc_pwd)

    # git branch + state
    set -l git (fish_git_prompt '%s' 2>/dev/null)
    if test -n "$git"
        set_color 565f89
        echo -n ' on '
        echo -n $git
    end

    # python virtualenv
    if set -q VIRTUAL_ENV
        set_color 565f89
        echo -n ' via '
        set_color 73daca
        echo -n (string replace -r '.*/' '' -- $VIRTUAL_ENV)
    end

    # exit code of the last command, if it failed
    if test $last_status -ne 0
        set_color --bold f7768e
        echo -n "  ✘ $last_status"
    end

    # │ spacer line (the little gap between the info line and the arrow)
    set_color normal
    echo
    set_color 565f89
    echo '│'

    # ╰─❯ arrow line
    echo -n '╰─'
    if test $last_status -eq 0
        set_color --bold 9ece6a
    else
        set_color --bold f7768e
    end
    echo -n '❯ '
    set_color normal
end
FISH_PROMPT

    # Foot can override TERM (Omarchy uses xterm-256color), but it reports its
    # identity through XTVERSION. Detect it at fish_prompt time, when Fish makes
    # status terminal available, before drawing the first prompt.
    cat > "$reflow_tmp" <<'FISH_REFLOW'
# fish-look-cool · detect Foot even when TERM is set to xterm-256color.
# Runs once. `status terminal` needs fish 4.1+; older fish falls back to $TERM.
function __flc_detect_foot_reflow --on-event fish_prompt
    functions -e __flc_detect_foot_reflow
    set -l terminal_id (status terminal 2>/dev/null)
    if string match -q 'foot*' -- "$TERM"; or string match -q 'foot*' -- "$terminal_id"
        set -g fish_handle_reflow 0
    end
end
FISH_REFLOW

    # Validate every new Fish file before replacing anything.
    if ! "$FISH_PATH" -n "$prompt_tmp" || ! "$FISH_PATH" -n "$reflow_tmp"; then
        die "Fish found a syntax problem in the new prompt; existing files were left unchanged."
    fi

    backup_if_exists "$prompt_file" "$prompt_tmp"
    backup_if_exists "$right_file"
    backup_if_exists "$reflow_file" "$reflow_tmp"

    chmod 0644 "$prompt_tmp" "$reflow_tmp"
    if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
        chown "$TARGET_USER:$target_group" "$prompt_tmp" "$reflow_tmp"
    fi

    # Each rename is atomic because staging and destination share a filesystem.
    mv -f -- "$prompt_tmp" "$prompt_file"
    # Preserve any previously installed right prompt above, then remove it so
    # older installs stop showing the clock and command durations.
    if [[ -f "$right_file" ]]; then
        rm -- "$right_file"
    fi
    mv -f -- "$reflow_tmp" "$reflow_file"
    rm -rf -- "$STAGING_DIR"
    STAGING_DIR=""
    ok "Prompt installed → $func_dir"
}

# Omarchy sets ~/.local/bin and mise (node, ruby, python…) up in bash only.
# Without this, those tools would vanish after switching to fish.
install_omarchy_basics() {
    local conf_dir="$1" target_group="$2"
    local f="$conf_dir/fish-look-cool-omarchy.fish"
    cat > "$f" <<'FISH_OMARCHY'
# fish-look-cool · Omarchy basics that its bash config normally provides
if status is-interactive
    test -d ~/.local/bin; and fish_add_path -g -a ~/.local/bin
    command -q mise; and mise activate fish | source
end
FISH_OMARCHY
    chmod 0644 "$f"
    if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
        chown "$TARGET_USER:$target_group" "$f"
    fi
    ok "Omarchy PATH + mise support added for fish"
}

# ── remove the boring welcome message ─────────────────────────────────────────
disable_greeting() {
    # Run as the target user so the universal variable lands in THEIR fish_variables.
    if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$FISH_PATH" -c 'set -U fish_greeting ""'
    else
        "$FISH_PATH" -c 'set -U fish_greeting ""'
    fi
    ok "Greeting removed"
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    printf '\n%s  🐟  fish-look-cool%s\n\n' "$C_B" "$C_0"

    if [[ $PROMPT_ONLY -eq 1 ]]; then
        FISH_PATH="$(command -v fish)" || die "fish is not installed yet. Run without --prompt-only first."
        info "Configuring for user: $TARGET_USER"
        info "Installing the custom prompt…"
        install_prompt
        printf '\n%s  Prompt updated! 🎉%s\n' "$C_G" "$C_0"
        printf '  Run  exec fish  (or open a new terminal) to see it.\n\n'
        return 0
    fi

    detect_os
    info "Detected: $OS_NAME  (package manager: $PM)"
    if [[ $IS_OMARCHY -eq 1 ]]; then
        info "Omarchy detected — will configure terminal + bash wrapper (safe for boot)"
    fi
    info "Configuring for user: $TARGET_USER"

    start_sudo_keepalive

    if [[ $UPDATE_SYSTEM -eq 1 ]]; then
        info "Updating & upgrading the system (this can take a while)…"
    fi
    update_system
    if [[ $UPDATE_SYSTEM -eq 1 ]]; then
        ok "System is up to date"
    fi

    info "Installing fish…"
    install_fish
    ok "fish installed: $("$FISH_PATH" --version)"

    info "Setting fish as the default shell…"
    set_default_shell

    info "Removing the fish greeting…"
    disable_greeting

    info "Installing the custom prompt…"
    install_prompt

    # On Omarchy, add PATH + mise support after the prompt is installed.
    if [[ $IS_OMARCHY -eq 1 ]]; then
        local conf_dir="$TARGET_HOME/.config/fish/conf.d"
        local target_group
        if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
            target_group="$(id -gn "$TARGET_USER")"
        fi
        install_omarchy_basics "$conf_dir" "${target_group:-}"
    fi

    printf '\n%s  All done! 🎉%s\n' "$C_G" "$C_0"

    if [[ $IS_OMARCHY -eq 1 ]]; then
        printf '  Omarchy: fish will launch in new terminal windows.\n'
        printf '  Your login shell remains bash (required for boot).\n\n'
    else
        printf '  fish is your default shell from your next login.\n\n'
    fi

    # Drop straight into fish so the new look shows up right now.
    if [[ -t 0 && -t 1 && $EUID -ne 0 ]]; then
        cleanup
        exec "$FISH_PATH"
    else
        printf '  Log out and back in (or open a new terminal) to see it.\n\n'
    fi
}

main "$@"