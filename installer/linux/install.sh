#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  ZPause Manager -- every game ZPause runs on.
#
#  Black Ops II, Black Ops and World at War on Plutonium; Black Ops III on
#  BOIII, T7x or the t7-compiler; Black Ops 4 on Project BO4 / Shield.
#
#  The twin of install.ps1, and it does the same things: finds each game
#  you have, shows what is already there, and installs, updates or removes
#  ZPause for any of them. It can fetch the latest release from GitHub, and keep a
#  copy of itself so you never have to go looking for the download again.
#
#  It only ever writes or removes zpause.gsc, at paths it found itself. It
#  never deletes a folder it did not create, and nothing leaves this machine
#  unless you say yes to a version check.
#
#  Plutonium is a Windows program, so on Linux it lives inside a Wine or
#  Proton prefix. This looks through the usual ones -- Lutris, Bottles,
#  plain ~/.wine, Steam's compatdata including a Steam Deck's, Heroic, and
#  the Flatpak versions of each -- and asks if it cannot find yours.
#
#  It also takes arguments, so one line can do the whole job:
#
#      ./install.sh --find              show what it detects, change nothing
#      ./install.sh --install --yes     install, asking nothing
#      ./install.sh --uninstall --yes   remove every copy it can find
#      ./install.sh --list              what is installed, then stop
#      ./install.sh --configure         open the settings editor
#      ./install.sh --game t8           skip the "which one?" question
#      ./install.sh --to ~/Plutonium    skip the "where?" question
# ---------------------------------------------------------------------
set -u

FINDONLY=0
# Plain output. There is no colour here to turn off, so what this changes is
# the progress bar: lines instead of one redrawn in place, which is what
# makes a captured transcript readable. NO_COLOR is the usual convention.
PLAIN=0
[ -n "${NO_COLOR:-}" ] && PLAIN=1
DO_INSTALL=0
DO_UNINSTALL=0
DO_LIST=0
DO_CONFIGURE=0
ASSUME_YES=0
WANT_GAME=""
WANT_TO=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --find)      FINDONLY=1 ;;
        --install)   DO_INSTALL=1 ;;
        --uninstall) DO_UNINSTALL=1 ;;
        --list)      DO_LIST=1 ;;
        --configure|--settings) DO_CONFIGURE=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
        --no-colour|--no-color|--plain) PLAIN=1 ;;
        --game)      WANT_GAME="${2:-}"; shift ;;
        --to)        WANT_TO="${2:-}"; shift ;;
        *) printf '\n  Not an option: %s\n  Try --find, --install, --uninstall, --list, --configure, --yes, --game, --to\n\n' "$1"; exit 1 ;;
    esac
    shift
done

# The window is the whole interface, so it is worth naming, and worth being
# wide enough that the installed-versions table does not wrap. Both are best
# effort: a terminal that ignores either is not an error.
if [ -t 1 ]; then
    printf '\033]0;ZPause Manager\007'
    if command -v tput >/dev/null 2>&1 && [ "$(tput cols 2>/dev/null || echo 99)" -lt 84 ]; then
        printf '\033[8;0;84t'
    fi
fi

say()   { printf '  %s\n' "$*"; }
blank() { printf '\n'; }
head_() { printf '\n  %s\n  %s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
have()  { command -v "$1" >/dev/null 2>&1; }

readl() {  # readl VAR -- a line from the terminal into VAR; a closed stdin stops the run
    # read fails at end of input but still hands over a last line with no
    # newline, which is worth keeping. With nothing at all, nobody is there
    # to answer: say which flags would have, rather than default an answer
    # or spin on an empty one.
    read -r "$1" && return 0
    [ -n "${!1}" ] && return 0
    blank
    say "No terminal to read from -- stopping here."
    say "For a run that asks nothing: --install --yes (add --game and --to as needed),"
    say "--uninstall --yes, --list or --find."
    blank
    exit 2
}

ask() {  # ask "question" [y|n]
    local q="$1" d="${2:-n}" hint a
    if [ "$d" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    # --yes is consent given on the command line. The question is still
    # printed, so a scripted run reads like an interactive one.
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf '  %s %s y\n' "$q" "$hint"
        return 0
    fi
    printf '  %s %s ' "$q" "$hint"
    readl a
    a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$a" ]; then
        [ "$d" = "y" ] && return 0
        return 1
    fi
    case "$a" in y*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------- where things are kept
STATE="${XDG_DATA_HOME:-$HOME/.local/share}/zpause"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/zpause"
SETTINGS="$STATE/settings.txt"

setting() {  # setting <key>
    [ -f "$SETTINGS" ] || return 0
    sed -n "s/^$1=//p" "$SETTINGS" | tail -n 1
}
set_setting() {  # set_setting <key> <value>
    mkdir -p "$STATE" 2>/dev/null || return 0
    local tmp="$SETTINGS.tmp"
    { [ -f "$SETTINGS" ] && grep -v "^$1=" "$SETTINGS"; printf '%s=%s\n' "$1" "$2"; } \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$SETTINGS"
}

# The Black Ops 4 installer this replaced remembered its game folder in a
# file of its own. Take it over once, so nobody is asked again for a path
# they already gave.
if [ -z "$(setting bo4)" ] && [ -f "$STATE/t8-path.txt" ]; then
    _old="$(head -n 1 "$STATE/t8-path.txt" 2>/dev/null)"
    [ -n "$_old" ] && [ -f "$_old/BlackOps4.exe" ] && set_setting bo4 "$_old"
    unset _old
fi

# ------------------------------------------------- the log
# Append-only, one line per file written or removed. It exists so "it did
# not work" can be answered with something concrete instead of a memory.
LOGFILE="$STATE/zpause.log"
log() {  # log <what> <detail>
    mkdir -p "$STATE" 2>/dev/null || return 0
    printf '%s  %-10s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOGFILE" 2>/dev/null
}

# ------------------------------------------------- backups
# The version library can put back any version this ever downloaded. It
# cannot put back a file somebody edited by hand, so the file being
# overwritten is copied out first, with an index saying where it came from
# -- a pile of identically named scripts cannot be restored without one.
BACKUPS="$STATE/backups"
BACKUP_INDEX="$BACKUPS/index.txt"
RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_N=0

backup_file() {  # backup_file <path>
    [ -f "${1:-}" ] || return 0
    local dir name
    dir="$BACKUPS/$RUN_STAMP"
    mkdir -p "$dir" 2>/dev/null || return 0
    BACKUP_N=$((BACKUP_N + 1))
    name="$(printf '%02d.gsc' "$BACKUP_N")"
    cp -f "$1" "$dir/$name" 2>/dev/null || return 0
    printf '%s|%s|%s|%s\n' "$RUN_STAMP" "$name" "$(read_version "$1")" "$1" \
        >> "$BACKUP_INDEX" 2>/dev/null
}

pretty_stamp() {
    printf '%s' "${1:-}" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2}).*/\1-\2-\3 \4:\5/'
}

# ------------------------------------------------- being offline
OFFLINE=0
net_problem() {  # net_problem [detail]
    # One line somebody can act on. A missing release is not a missing
    # internet, and saying so saves a pointless retry.
    case "${1:-}" in
        *404*) say "That one has no published release yet."; return 0 ;;
    esac
    OFFLINE=1
    say "GitHub is not reachable -- you may be offline."
    say "Everything else here works without it."
}
net_ready() {
    if [ "$OFFLINE" -eq 1 ]; then
        say "Still offline, so nothing was contacted."
        return 1
    fi
    return 0
}

# ------------------------------------------------- the download root
# This lives in installer/linux/, so the mod files and the manifest are two
# levels up. Walk until zpause.release turns up; if it never does, this is a
# kept copy with no mod files beside it and everything comes from GitHub.
find_root() {  # find_root <start>
    local r="$1" i
    for i in 1 2 3 4 5; do
        [ -f "$r/zpause.release" ] && { printf '%s' "$r"; return 0; }
        [ "$r" = "/" ] && return 1
        r="$(dirname "$r")"
    done
    return 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(find_root "$HERE" || true)"

REL_NAME=""; REL_VERSION=""; REL_GAME=""; REL_REPO=""; REL_ASSET=""
read_release() {  # read_release <root>
    REL_NAME=""; REL_VERSION=""; REL_GAME=""; REL_REPO=""; REL_ASSET=""
    [ -n "${1:-}" ] || return 0
    if [ -f "$1/zpause.release" ]; then
        REL_NAME="$(sed -n 's/^name=//p' "$1/zpause.release" | tail -n 1)"
        REL_VERSION="$(sed -n 's/^version=//p' "$1/zpause.release" | tail -n 1)"
        REL_GAME="$(sed -n 's/^game=//p' "$1/zpause.release" | tail -n 1)"
        REL_REPO="$(sed -n 's/^repo=//p' "$1/zpause.release" | tail -n 1)"
        REL_ASSET="$(sed -n 's/^asset=//p' "$1/zpause.release" | tail -n 1)"
    fi
    # Releases before v1.4 have no manifest at all, so the name the download
    # arrived under is the fallback -- it says both things.
    name_of "$1"
}

name_of() {  # fill in REL_NAME / REL_VERSION from a folder name
    local leaf
    leaf="$(basename "${1:-}")"
    [ -n "$REL_VERSION" ] || REL_VERSION="$(printf '%s' "$leaf" |
        sed -n 's/.*[ .]v\([0-9][0-9.]*d\?\)\([ .].*\)\{0,1\}$/\1/p')"
    [ -n "$REL_NAME" ] || REL_NAME="$(printf '%s' "$leaf" |
        sed 's/[ .]v[0-9].*$//; s/\./ /g')"
}
read_release "$ROOT"
source_of() {  # where a download keeps the files to install
    # A download carries one or more drop-in trees; a source folder carries
    # the script flat beside the manifest. Whichever it is, this is the
    # thing payload_for reads the per-game files out of.
    [ -n "${1:-}" ] || return 0
    local t
    for t in Plutonium "Black Ops III" zpause; do
        [ -d "$1/$t" ] && { printf '%s' "$1"; return 0; }
    done
    for t in zpause.gsc zpause_t7x.gscc metadata.json; do
        [ -f "$1/$t" ] && { printf '%s' "$1"; return 0; }
    done
    return 0
}

is_download() {  # only a real download has a manifest worth checking
    [ -n "${1:-}" ] || return 1
    local t
    for t in Plutonium "Black Ops III" t7x zpause; do
        [ -d "$1/$t" ] && return 0
    done
    return 1
}

SRC="$(source_of "${ROOT:-}")"
HOME_ROOT="${ROOT:-}"

# ------------------------------------------------- what can be downloaded
# Used when this installer arrived on its own, with no mod files beside it:
# it can still fetch any of them. T7 is here because it is a ZPause release
# like the rest; it installs into Black Ops III rather than into Plutonium,
# so it is handed to its own installer once it has been unpacked.
CAT_KEY=(bundle t6 t5 t4 t7 t8)
CAT_NAME=("ZPause [Treyarch Bundle]" "ZPause T6" "ZPause T5" "ZPause T4" "ZPause T7" "ZPause T8")
CAT_REPO=("Xeptix/ZPause" "Xeptix/ZPause" "Xeptix/ZPauseT5" "Xeptix/ZPauseT4" "Xeptix/ZPauseT7" "Xeptix/ZPauseT8")
CAT_ASSET=("ZPause [Treyarch Bundle] v" "ZPause T6 v" "ZPause T5 v" "ZPause T4 v" "ZPause T7 v" "ZPause T8 v")
CAT_WHAT=("all five games in one download" "Black Ops II only" \
          "Black Ops only" "World at War only" "Black Ops III only" "Black Ops 4 only")

# Where the list of other mods lives. It is optional: when the file is not
# in the repo, nothing is shown and nothing is said about it.
HOME_REPO="Xeptix/ZPause"
OTHER_MODS="OTHERMODS.MD"

ONLINE=0
DOWNLOADED=0
N_INSTALLED=0
N_REMOVED=0
N_RESTORED=0
N_SETTINGS=0
N_DROPPED=0
DID_INSTALL=0
LATEST_VERSION=""

# ------------------------------------------------- version arithmetic
# A public version is X.Y. A development build appends .N.d and is working
# towards X.Y, so it sorts below the release of the same number.
ver_key() {  # ver_key 1.4.2.d -> sortable string, empty if not a version
    case "${1:-}" in
        [0-9]*.[0-9]*.[0-9]*.d)
            printf '%05d %05d 0 %05d' "$(echo "$1" | cut -d. -f1)" \
                   "$(echo "$1" | cut -d. -f2)" "$(echo "$1" | cut -d. -f3)" ;;
        [0-9]*.[0-9]*)
            printf '%05d %05d 1 00000' "$(echo "$1" | cut -d. -f1)" \
                   "$(echo "$1" | cut -d. -f2)" ;;
        *) printf '' ;;
    esac
}
ver_cmp() {  # ver_cmp a b -> echoes -1, 0 or 1 (0 when either is unreadable)
    local x y
    x="$(ver_key "${1:-}")"; y="$(ver_key "${2:-}")"
    if [ -z "$x" ] || [ -z "$y" ]; then echo 0; return; fi
    if [ "$x" = "$y" ]; then echo 0
    elif [ "$x" \> "$y" ]; then echo 1
    else echo -1; fi
}

printf '\n  ZPause Manager\n  ==============\n'
if [ -n "$REL_NAME" ]; then
    say "$REL_NAME v$REL_VERSION"
else
    say "no mod files beside this installer -- they can be downloaded"
fi

# ------------------------------------------------- the games
# One entry per game ZPause runs on, and the family says how it installs,
# because there are three shapes rather than five:
#
#   pluto   loose scripts at fixed paths under one Plutonium folder
#   bo3     up to three routes under a Black Ops III folder, one of which
#           takes a compiled build rather than the raw script
#   bo4     a whole mod folder copied under project-bo4/mods
#
# Everything past this point -- the manager, the cache, the GitHub fetch,
# backups, the log, the doctor, profiles, the shortcut -- is the same for
# all five and is written once.
G_KEY=(t6 t5 t4 t7 t8)
G_TAG=(T6 T5 T4 T7 T8)
G_NAME=("Black Ops II" "Black Ops" "World at War" "Black Ops III" "Black Ops 4")
G_FAM=(pluto pluto pluto bo3 bo4)

declare -A GAME_NAMES=([t6]="Black Ops II" [t5]="Black Ops" [t4]="World at War" \
                        [t7]="Black Ops III" [t8]="Black Ops 4")
declare -A GAME_TAG=([t6]=T6 [t5]=T5 [t4]=T4 [t7]=T7 [t8]=T8)
declare -A GAME_FAM=([t6]=pluto [t5]=pluto [t4]=pluto [t7]=bo3 [t8]=bo4)
declare -A FAM_LABEL=([pluto]="Plutonium" [bo3]="Black Ops III" [bo4]="Black Ops 4")

game_index() {  # game_index <key> -> prints the index into G_*, or nothing
    local i
    for i in "${!G_KEY[@]}"; do [ "${G_KEY[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }; done
    return 1
}

# What a folder has to contain to be that family's root. Any one of the
# markers will do: a Black Ops III folder may carry BlackOps3.exe, or only
# boiii.exe or t7x.exe if it is a client-only install.
is_root() {  # is_root <family> <path>
    [ -n "${2:-}" ] || return 1
    case "$1" in
        pluto) [ -d "$2/storage" ] ;;
        bo3)   [ -f "$2/BlackOps3.exe" ] || [ -f "$2/boiii.exe" ] || [ -f "$2/t7x.exe" ] ;;
        bo4)   [ -f "$2/BlackOps4.exe" ] ;;
        *) return 1 ;;
    esac
}

FOUND=()
consider() {  # consider <family> <path> -- a candidate counts once, if it is one
    [ -n "${2:-}" ] || return 0
    is_root "$1" "$2" || return 0
    local p
    for p in "${FOUND[@]-}"; do [ "$p" = "$2" ] && return 0; done
    FOUND+=("$2")
}

# Steam's own library list beats guessing at paths: it names every library,
# including one on an SD card, which is where a Deck is as likely as not to
# keep a game.
LIBS=()
add_lib() {
    [ -n "${1:-}" ] && [ -d "$1/steamapps" ] || return 0
    local l
    for l in "${LIBS[@]-}"; do [ "$l" = "$1" ] && return 0; done
    LIBS+=("$1")
}
find_libs() {
    LIBS=()
    local ROOTS=(
        "$HOME/.steam/steam" "$HOME/.steam/root" "$HOME/.local/share/Steam"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
    )
    local m r vdf lib
    # SteamOS mounts removable storage differently depending on its age.
    for m in /run/media/mmcblk0p1 /run/media/deck/* /run/media/*; do
        [ -d "$m/steamapps" ] && ROOTS+=("$m")
    done
    for r in "${ROOTS[@]}"; do
        add_lib "$r"
        vdf="$r/steamapps/libraryfolders.vdf"
        if [ -f "$vdf" ]; then
            while IFS= read -r lib; do add_lib "$lib"; done \
                < <(grep -oE '"path"[[:space:]]+"[^"]+"' "$vdf" 2>/dev/null |
                    sed -E 's/.*"path"[[:space:]]+"([^"]+)".*/\1/')
        fi
    done
}
find_libs

# Plutonium is a Windows program, so on Linux it lives inside a Wine or
# Proton prefix: DeckOps' compatdata prefix (users/steamuser, on any
# library), Heroic's shared prefix, Lutris, Bottles, plain ~/.wine, and the
# Flatpak build of each.
scan_prefixes() {  # scan_prefixes <root>
    local root="$1" pfx
    [ -d "$root" ] || return 0
    for pfx in "$root"/*/pfx/drive_c/users/*/AppData/Local/Plutonium \
               "$root"/*/drive_c/users/*/AppData/Local/Plutonium \
               "$root"/drive_c/users/*/AppData/Local/Plutonium; do
        consider pluto "$pfx"
    done
}

find_roots() {  # find_roots <family> -> FOUND
    FOUND=()
    local l d
    case "$1" in
        pluto)
            for l in "${LIBS[@]-}"; do scan_prefixes "$l/steamapps/compatdata"; done
            scan_prefixes "$HOME/Games/Heroic/Prefixes"
            scan_prefixes "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/Prefixes"
            scan_prefixes "$HOME/Games"
            scan_prefixes "$HOME/.local/share/lutris/prefixes"
            scan_prefixes "$HOME/.var/app/net.lutris.Lutris/data/lutris/prefixes"
            scan_prefixes "$HOME/.local/share/bottles/bottles"
            scan_prefixes "$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles"
            scan_prefixes "$HOME/.wine"
            scan_prefixes "$HOME/.local/share/wineprefixes"
            consider pluto "$HOME/.local/share/Plutonium"
            consider pluto "$HOME/Plutonium"
            ;;
        bo3)
            for l in "${LIBS[@]-}"; do
                consider bo3 "$l/steamapps/common/Call of Duty Black Ops III"
            done
            for d in "$HOME/Games/Call of Duty Black Ops III" "$HOME/Call of Duty Black Ops III" \
                     "$HOME/Games/COD/Call of Duty Black Ops III" \
                     "$HOME/Games/Call of Duty/Black Ops III" /opt/games/*/ /games/*/; do
                consider bo3 "${d%/}"
            done
            ;;
        bo4)
            for l in "${LIBS[@]-}"; do
                consider bo4 "$l/steamapps/common/Call of Duty Black Ops 4"
                consider bo4 "$l/steamapps/common/Call of Duty Black Ops IIII"
            done
            for d in "$HOME/Games/Call of Duty Black Ops 4" "$HOME/Games/BlackOps4" \
                     "$HOME/Call of Duty Black Ops 4" "$HOME/BlackOps4" \
                     "$HOME/Games/COD/Call of Duty Black Ops 4" "$HOME/Games/COD/BlackOps4" \
                     "$HOME/Games/Call of Duty/Black Ops 4" /opt/games/*/ /games/*/; do
                consider bo4 "${d%/}"
            done
            ;;
    esac
}

# One prefix serves both Black Ops III clients: BOIII and T7x sit side by
# side under AppData/Local as boiii/data and t7x/data. Find it once.
APPID=311210
APPDATA=""
APPDATA_T7X=""
find_appdata() {
    APPDATA=""; APPDATA_T7X=""
    local l pfx h root=""
    for l in "${LIBS[@]-}"; do
        pfx="$l/steamapps/compatdata/$APPID/pfx/drive_c/users/steamuser/AppData/Local"
        [ -d "$pfx" ] || continue
        root="$pfx"
        [ -d "$pfx/boiii/data" ] || [ -d "$pfx/t7x/data" ] && break
    done
    if [ -z "$root" ]; then
        for h in "$HOME/Games/Heroic/Prefixes"/*/drive_c/users/*/AppData/Local \
                 "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/Prefixes"/*/drive_c/users/*/AppData/Local; do
            [ -d "$h" ] || continue
            root="$h"
            [ -d "$h/boiii/data" ] || [ -d "$h/t7x/data" ] && break
        done
    fi
    [ -n "$root" ] || return 0
    APPDATA="$root/boiii/data"
    APPDATA_T7X="$root/t7x/data"
}
find_appdata

root_hint() {  # root_hint <family>
    case "$1" in
        pluto) say "It lives inside a Wine or Proton prefix, at a path ending:"
               say "    drive_c/users/<you>/AppData/Local/Plutonium" ;;
        bo3)   say "It is the folder with BlackOps3.exe in it." ;;
        bo4)   say "It is the folder with BlackOps4.exe in it." ;;
    esac
}
root_needs() {  # root_needs <family>
    case "$1" in
        pluto) printf 'a storage folder inside it' ;;
        bo3)   printf 'BlackOps3.exe, boiii.exe or t7x.exe in it' ;;
        bo4)   printf 'BlackOps4.exe in it' ;;
    esac
}

# Pointing at the folder that holds the install is the common slip.
settle_root() {  # settle_root <family> <typed> -> prints the root, or nothing
    local t="$2"
    t="${t%\"}"; t="${t#\"}"; t="${t/#\~/$HOME}"
    is_root "$1" "$t" && { printf '%s' "$t"; return 0; }
    [ "$1" = "pluto" ] && is_root pluto "$t/Plutonium" && { printf '%s' "$t/Plutonium"; return 0; }
    return 1
}

CHOSEN=""
choose_root() {  # choose_root <family> [force] -> CHOSEN
    local fam="$1" force="${2:-0}" label saved pick i typed p
    label="${FAM_LABEL[$fam]}"
    CHOSEN=""
    # A path given on the command line settles it outright.
    if [ -n "$WANT_TO" ] && [ "$force" -eq 0 ]; then
        CHOSEN="$(settle_root "$fam" "$WANT_TO")" && return 0
        say "That is not a $label folder: $WANT_TO"
        return 1
    fi
    # A remembered folder wins, so the second run asks nothing at all.
    saved="$(setting "$fam")"
    if [ "$force" -eq 0 ] && [ -n "$saved" ] && is_root "$fam" "$saved"; then
        CHOSEN="$saved"; return 0
    fi
    if [ "${#FOUND[@]}" -eq 1 ] && [ "$force" -eq 0 ]; then
        CHOSEN="${FOUND[0]}"; return 0
    fi
    if [ "${#FOUND[@]}" -ge 1 ]; then
        head_ "$label -- which one?"
        blank
        i=1; for p in "${FOUND[@]}"; do say "    $i. $p"; i=$((i + 1)); done
        say "    0. somewhere else -- I will type the path"
        blank
        printf '  which? '
        readl pick
        if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#FOUND[@]}" ] 2>/dev/null; then
            CHOSEN="${FOUND[$((pick - 1))]}"; return 0
        fi
        if [ "$pick" != "0" ]; then blank; say "Not one of the choices."; return 1; fi
    else
        head_ "$label"
        say "Could not find your $label install."
        blank
        root_hint "$fam"
    fi

    blank
    say "Paste the full path to your $label folder -- the one with"
    say "$(root_needs "$fam") -- or press Enter to give up."
    blank
    printf '  path: '
    readl typed
    [ -n "$typed" ] || return 1
    CHOSEN="$(settle_root "$fam" "$typed")" && return 0
    blank
    say "That folder does not have $(root_needs "$fam"), so it is probably not"
    say "your $label install."
    return 1
}

# The root each family resolved to. Only Plutonium is resolved up front;
# the others are found the first time a game in that family is wanted,
# and remembered from then on.
declare -A ROOTS=()
root_of() { printf '%s' "${ROOTS[$1]:-}"; }

root_quiet() {  # root_quiet <family> -> prints the root, without asking anybody
    local r saved
    r="${ROOTS[$1]:-}"
    [ -n "$r" ] && { printf '%s' "$r"; return 0; }
    saved="$(setting "$1")"
    if [ -n "$saved" ] && is_root "$1" "$saved"; then
        ROOTS[$1]="$saved"; printf '%s' "$saved"; return 0
    fi
    find_roots "$1"
    if [ "${#FOUND[@]}" -eq 1 ]; then
        ROOTS[$1]="${FOUND[0]}"
        set_setting "$1" "${FOUND[0]}"
        printf '%s' "${FOUND[0]}"; return 0
    fi
    return 1
}

root_ask() {  # root_ask <family> -> prints the root, asking if it must
    local r
    r="$(root_quiet "$1")" && { printf '%s' "$r"; return 0; }
    find_roots "$1"
    choose_root "$1" 0 || return 1
    ROOTS[$1]="$CHOSEN"
    [ "$(setting "$1")" = "$CHOSEN" ] || set_setting "$1" "$CHOSEN"
    printf '%s' "$CHOSEN"
}

if [ "$FINDONLY" -eq 1 ]; then
    for fam in pluto bo3 bo4; do
        head_ "${FAM_LABEL[$fam]}"
        find_roots "$fam"
        if [ "${#FOUND[@]}" -eq 0 ]; then say "none found"
        else for p in "${FOUND[@]}"; do say "$p"; done; fi
    done
    blank
    exit 0
fi

# Plutonium is the common case, so it is looked for now and named when it
# is found -- but never asked for here. A folder is only asked for when a
# game that needs it is chosen, so a Black Ops III or Black Ops 4 player is
# not stopped at the door with a question about a game they do not have.
PLUTO="$(root_quiet pluto)" || PLUTO=""
if [ -n "$PLUTO" ]; then
    head_ "Plutonium"
    say "$PLUTO"
fi

# ------------------------------------------------- what is installed
# Every place any of the five games can read ZPause from. Family says which
# root the path hangs off. Kind says what the slot is: a file, a folder
# (Black Ops 4 takes a whole mod folder), or a compiled file (T7x loads
# compiled GSC and nothing else). Black Ops III's loaders are optional and
# independent, so a route there carries the marker that says whether that
# loader is even present; the AppData route is judged by its own folder.
SLOT_KEY=( t6 t6 t6 t5 t4 t7 t7 t7 t8 )
SLOT_FAM=( pluto pluto pluto pluto pluto bo3 bo3 bo3 bo4 )
SLOT_KIND=( file file file file file file file compiled folder )
SLOT_GAME=("T6  Black Ops II" "T6  Black Ops II" "T6  mod version" \
           "T5  Black Ops" "T4  World at War" \
           "T7  BOIII / Ezz BOIII" "T7  BOIII (Proton AppData)" "T7  T7x" \
           "T8  Black Ops 4")
SLOT_PATH=("storage/t6/raw/scripts/zm/zpause.gsc" \
           "storage/t6/scripts/zm/zpause.gsc" \
           "storage/t6/mods/zm_pause/scripts/zm/zpause.gsc" \
           "storage/t5/raw/scripts/sp/zpause.gsc" \
           "storage/t4/raw/scripts/sp/zpause.gsc" \
           "boiii/custom_scripts/zpause.gsc" \
           "custom_scripts/zpause.gsc" \
           "t7x/custom_scripts/zpause.gsc" \
           "project-bo4/mods/zpause")
# A base of "-" means the family root; "appdata" means the BOIII prefix.
SLOT_BASE=( - - - - - - appdata - - )
SLOT_MARK=( - - - - - "boiii.exe boiii" "" "t7x.exe t7x" - )
SLOT_NOTE=("" "" "" "" "" "loose script, no mod slot" \
           "the same client, its other script folder" "compiled build, no mod slot" "")

slot_base() {  # slot_base <i>
    case "${SLOT_BASE[$1]}" in
        appdata) printf '%s' "$APPDATA" ;;
        *) root_quiet "${SLOT_FAM[$1]}" ;;
    esac
}
slot_path() {  # slot_path <i>
    local b
    b="$(slot_base "$1")" || return 1
    [ -n "$b" ] || return 1
    printf '%s/%s' "$b" "${SLOT_PATH[$1]}"
}
slot_present() {  # slot_present <i> -- is that loader even installed?
    local b m r
    [ "${SLOT_MARK[$1]}" = "-" ] && return 0
    b="$(slot_base "$1")" || return 1
    [ -n "$b" ] || return 1
    if [ -z "${SLOT_MARK[$1]}" ]; then [ -d "$b" ]; return $?; fi
    r="$(root_quiet "${SLOT_FAM[$1]}")" || return 1
    for m in ${SLOT_MARK[$1]}; do [ -e "$r/$m" ] && return 0; done
    return 1
}

read_version() {  # read_version <file>
    [ -f "$1" ] || return 1
    head -n 40 "$1" | sed -n 's/.*ZPAUSE\( T[0-9]\)\? v\([0-9][0-9.]*d\?\).*/\2/p' | head -n 1
}

slot_version() {  # slot_version <i> <full path> -> version, or nothing if absent
    local v ref
    if [ "${SLOT_KIND[$1]}" = "folder" ]; then
        # What the mod folder holds is compiled, so nothing in it says which
        # version it is. The stamp the installer wrote does.
        [ -f "$2/metadata.json" ] || return 1
        if [ -f "$2/zpause.installed" ]; then head -n 1 "$2/zpause.installed"; else printf '?'; fi
        return 0
    fi
    [ -f "$2" ] || return 1
    v="$(read_version "$2")"
    if [ -z "$v" ] && [ "${SLOT_KIND[$1]}" = "compiled" ]; then
        # A compiled script only shows a version at all because the build
        # stamp is a string literal, and a release build has no stamp. If
        # it is byte for byte what this download carries, it is this
        # download's version.
        ref="$(payload_for "${SLOT_KEY[$1]}" compiled)"
        [ -n "$ref" ] && [ -f "$ref" ] && cmp -s "$ref" "$2" && [ -n "$REL_VERSION" ] && v="$REL_VERSION"
    fi
    [ -n "$v" ] || v="?"
    printf '%s' "$v"
}

INST_KEY=(); INST_FAM=(); INST_KIND=(); INST_GAME=(); INST_PATH=(); INST_VER=()
get_installed() {
    INST_KEY=(); INST_FAM=(); INST_KIND=(); INST_GAME=(); INST_PATH=(); INST_VER=()
    local i full v
    for i in "${!SLOT_PATH[@]}"; do
        full="$(slot_path "$i")" || continue
        v="$(slot_version "$i" "$full")" || continue
        INST_KEY+=("${SLOT_KEY[$i]}"); INST_FAM+=("${SLOT_FAM[$i]}"); INST_KIND+=("${SLOT_KIND[$i]}")
        INST_GAME+=("${SLOT_GAME[$i]}"); INST_PATH+=("$full"); INST_VER+=("$v")
    done
}

short_path() {  # short_path <i into INST_*>
    local b
    b="$(root_of "${INST_FAM[$1]}")"
    if [ -n "$b" ]; then
        case "${INST_PATH[$1]}" in "$b"*) printf '...%s' "${INST_PATH[$1]#$b}"; return 0 ;; esac
    fi
    printf '%s' "${INST_PATH[$1]}"
}

show_installed() {
    head_ "Installed"
    get_installed
    if [ "${#INST_PATH[@]}" -eq 0 ]; then
        say "ZPause is not installed on this PC yet."
        return 0
    fi
    # Something to compare against: the mod files beside us, or whatever the
    # last GitHub check turned up, whichever is newer.
    local ref="$REL_VERSION" i c
    if [ -n "$LATEST_VERSION" ] && [ "$(ver_cmp "$LATEST_VERSION" "$ref")" = "1" ]; then
        ref="$LATEST_VERSION"
    fi
    blank
    local known edited note
    for i in "${!INST_PATH[@]}"; do
        note="v${INST_VER[$i]}"
        edited=0
        if [ "${INST_KIND[$i]}" != "folder" ]; then
            known="$(ref_for "${INST_VER[$i]}" "${INST_KEY[$i]}" "${INST_KIND[$i]}")"
            if [ -n "$known" ] && ! cmp -s "$known" "${INST_PATH[$i]}"; then edited=1; fi
        fi
        if [ "$edited" -eq 1 ]; then
            if is_applied "${INST_PATH[$i]}"; then note="$note, configured"
            else note="$note, modified"; fi
        fi
        printf '    %d. %-24s %-18s %s\n' "$((i + 1))" "${INST_GAME[$i]}" "$note" "$(short_path "$i")"
        if [ "$edited" -eq 1 ]; then
            if is_applied "${INST_PATH[$i]}"; then
                say "       carries your saved settings"
            else
                say "       does not match that version -- edited since it was installed"
            fi
        fi
        if [ -n "$ref" ]; then
            c="$(ver_cmp "${INST_VER[$i]}" "$ref")"
            [ "$c" = "-1" ] && say "       older than v$ref"
            if [ "$c" = "0" ] && [ "$edited" -eq 0 ]; then say "       up to date"; fi
        fi
    done
}

# ------------------------------------------------- downloading
fmt_bytes() {
    local n="${1:-0}"
    if [ "$n" -ge 1048576 ]; then awk -v n="$n" 'BEGIN{printf "%.1f MB", n/1048576}'
    elif [ "$n" -ge 1024 ]; then awk -v n="$n" 'BEGIN{printf "%.0f KB", n/1024}'
    else printf '%d B' "$n"; fi
}

progress() {  # progress <got> <total> <seconds>
    local got="$1" total="$2" secs="$3" width=28 fill pct bar line
    if [ "$total" -gt 0 ]; then
        fill=$(( got * width / total ))
        [ "$fill" -gt "$width" ] && fill=$width
        pct=$(( got * 100 / total ))
        bar="$(printf '%*s' "$fill" '' | tr ' ' '#')"
        bar="$bar$(printf '%*s' "$((width - fill))" '' | tr ' ' '-')"
        line="$(printf '  [%s] %3d%%  %s of %s' "$bar" "$pct" \
                "$(fmt_bytes "$got")" "$(fmt_bytes "$total")")"
    else
        line="$(printf '  %s downloaded' "$(fmt_bytes "$got")")"
    fi
    [ "$secs" -gt 0 ] && line="$line  $(fmt_bytes $((got / secs)))/s"
    if [ "$PLAIN" -eq 1 ]; then
        # One line at a time, so a pasted transcript reads properly.
        local tenth=0
        [ "$total" -gt 0 ] && tenth=$(( got * 10 / total ))
        if [ "$tenth" != "$LAST_TENTH" ]; then
            LAST_TENTH="$tenth"
            printf '%s\n' "$line"
        fi
        return 0
    fi
    printf '\r%-74s' "$line"
}
LAST_TENTH=-1

remote_size() {  # remote_size <url> -- 0 when the server will not say
    local n=""
    if have curl; then
        n="$(curl -fsIL -A ZPause-Manager "$1" 2>/dev/null |
             tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: //p' | tail -n 1)"
    elif have wget; then
        n="$(wget -q --spider --server-response "$1" 2>&1 |
             tr -d '\r' | sed -n 's/^ *[Cc]ontent-[Ll]ength: //p' | tail -n 1)"
    fi
    case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

fetch() {  # fetch <url> <dest> [quiet] -- with a progress bar of our own
    local url="$1" dest="$2" quiet="${3:-0}" total=0 pid got t0 rc
    have curl || have wget || { say "Needs curl or wget, and neither is installed."; return 1; }
    mkdir -p "$(dirname "$dest")" 2>/dev/null

    if [ "$quiet" = "1" ]; then
        if have curl; then curl -fsL -A ZPause-Manager -o "$dest" "$url" 2>/dev/null
        else wget -q -O "$dest" "$url" 2>/dev/null; fi
        return $?
    fi

    total="$(remote_size "$url")"
    # curl and wget both draw their own progress, and neither says how fast
    # or how far in the same breath. Ours is polled off the part file, which
    # also makes it identical to the Windows installer's.
    if have curl; then
        curl -fsL -A ZPause-Manager -o "$dest.part" "$url" &
    else
        wget -q -O "$dest.part" "$url" &
    fi
    pid=$!
    t0=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        got="$(stat -c %s "$dest.part" 2>/dev/null || echo 0)"
        progress "$got" "$total" "$((SECONDS - t0))"
        sleep 0.2
    done
    wait "$pid"; rc=$?
    got="$(stat -c %s "$dest.part" 2>/dev/null || echo 0)"
    progress "$got" "$total" "$((SECONDS - t0))"
    printf '\n'
    if [ "$rc" -ne 0 ] || [ "$got" -eq 0 ]; then
        rm -f "$dest.part"
        net_problem
        return 1
    fi
    mv -f "$dest.part" "$dest"
}

unpack() {  # unpack <zip> <dir>
    rm -rf "$2"; mkdir -p "$2" || return 1
    if have unzip; then unzip -qo "$1" -d "$2"
    elif have bsdtar; then bsdtar -xf "$1" -C "$2"
    elif have python3; then python3 -c "import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$1" "$2"
    else say "Needs unzip, bsdtar or python3 to open the download."; return 1; fi
}

# ------------------------------------------------- github
LATEST_URL=""; LATEST_NAME=""; LATEST_SIZE=0; LATEST_SUMS=""

norm_name() {
    # Letters and digits, lowercased. Everything else is punctuation that a
    # download can pick up or lose on the way through GitHub.
    printf '%s' "${1:-}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]'
}

get_latest() {  # get_latest <repo> <asset prefix>
    LATEST_VERSION=""; LATEST_URL=""; LATEST_NAME=""; LATEST_SIZE=0
    net_ready || return 1
    local api json urls u base
    api="https://api.github.com/repos/$1/releases/latest"
    if have curl; then json="$(curl -fsL -A ZPause-Manager "$api" 2>/dev/null)"
    elif have wget; then json="$(wget -qO- "$api" 2>/dev/null)"
    else say "Needs curl or wget, and neither is installed."; return 1; fi
    [ -n "$json" ] || { net_problem; return 1; }

    LATEST_VERSION="$(printf '%s' "$json" |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"[^"]*[vV]\?\([0-9][0-9.]*\)".*/\1/p' | head -n 1)"

    urls="$(printf '%s' "$json" |
        grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' |
        sed 's/.*"\(https[^"]*\)"/\1/')"

    # GitHub rewrites the spaces in an uploaded asset's name, so what goes up
    # as "ZPause T6 v1.3 by Xep.zip" comes back as "ZPause.T6.v1.3.by.Xep.zip".
    # Comparing on letters and digits alone survives that -- and still tells
    # "ZPause T7" apart from "ZPause T7 Workshop", which a looser match would
    # not, and which is the whole reason the prefix exists.
    local want
    want="$(norm_name "$2")"
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        base="$(basename "$u" | sed 's/%20/ /g; s/%5B/[/g; s/%5D/]/g')"
        case "$base" in
            *.zip)
                case "$(norm_name "$base")" in
                    "$want"*) LATEST_URL="$u"; LATEST_NAME="$base"; break ;;
                esac ;;
        esac
    done <<< "$urls"
    if [ -z "$LATEST_URL" ]; then
        while IFS= read -r u; do
            case "$u" in *.zip) LATEST_URL="$u"
                LATEST_NAME="$(basename "$u" | sed 's/%20/ /g; s/%5B/[/g; s/%5D/]/g')"
                break ;;
            esac
        done <<< "$urls"
    fi
    # A manifest attached to the release itself, if there is one. The
    # manifest inside a zip cannot vouch for the zip.
    while IFS= read -r u; do
        base="$(basename "$u")"
        case "$base" in SHA256SUMS|*.sha256) LATEST_SUMS="$u"; break ;; esac
    done <<< "$urls"
    [ -n "$LATEST_URL" ] || { say "That release has no zip attached to it."; return 1; }
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION="$(printf '%s' "$LATEST_NAME" |
            sed -n 's/.*[ .]v\([0-9][0-9.]*d\?\)[ .].*/\1/p')"
    fi
}

# ------------------------------------------------- the version library
#
# Every download is kept, and nothing here is deleted on its own. An older
# build is worth having when a newer one misbehaves, and keeping them is
# what turns going back into a menu entry rather than a trip to GitHub.
LIB_NAME=(); LIB_VER=(); LIB_DIR=(); LIB_ZIP=(); LIB_SRC=()
root_in() {  # root_in <extracted folder>
    # The manifest is at the top of a download, or one folder down if the
    # zip was made with a wrapper. Never above: walking up out of the
    # extracted folder would adopt somebody else's manifest.
    local d
    if [ -f "$1/zpause.release" ]; then printf '%s' "$1"; return 0; fi
    for d in "$1"/*/; do
        d="${d%/}"
        [ -f "$d/zpause.release" ] && { printf '%s' "$d"; return 0; }
    done
    printf '%s' "$1"
}

get_library() {
    LIB_NAME=(); LIB_VER=(); LIB_DIR=(); LIB_ZIP=(); LIB_SRC=()
    [ -d "$CACHE" ] || return 0
    # name_of writes to REL_NAME/REL_VERSION, which belong to the session.
    # Borrow them and hand them back.
    local d n v src _keep_n="$REL_NAME" _keep_v="$REL_VERSION"
    for d in "$CACHE"/*/; do
        d="${d%/}"
        [ -d "$d" ] || continue
        n=""; v=""
        if [ -f "$d/zpause.release" ]; then
            n="$(sed -n 's/^name=//p' "$d/zpause.release" | tail -n 1)"
            v="$(sed -n 's/^version=//p' "$d/zpause.release" | tail -n 1)"
        fi
        REL_NAME="$n"; REL_VERSION="$v"
        name_of "$d"
        n="$REL_NAME"; v="$REL_VERSION"
        src="$(source_of "$d")"
        [ -n "$src" ] && [ -e "$src" ] || continue
        LIB_NAME+=("$n"); LIB_VER+=("$v"); LIB_DIR+=("$d")
        LIB_ZIP+=("$CACHE/$(basename "$d").zip"); LIB_SRC+=("$src")
    done
    REL_NAME="$_keep_n"; REL_VERSION="$_keep_v"
}

CH_NAME=(); CH_VER=(); CH_DIR=(); CH_SRC=(); CH_HERE=()
get_choices() {
    # What could be installed right now: whatever came with this download,
    # then everything kept from an earlier one.
    CH_NAME=(); CH_VER=(); CH_DIR=(); CH_SRC=(); CH_HERE=()
    # HOME_ROOT, not ROOT: adopting a download moves ROOT into the cache, and
    # the version you started with must not vanish off the list.
    local mine i n v _keep_n="$REL_NAME" _keep_v="$REL_VERSION"
    mine="$(source_of "${HOME_ROOT:-}")"
    if [ -n "$mine" ] && [ -e "$mine" ]; then
        n=""; v=""
        if [ -f "$HOME_ROOT/zpause.release" ]; then
            n="$(sed -n 's/^name=//p' "$HOME_ROOT/zpause.release" | tail -n 1)"
            v="$(sed -n 's/^version=//p' "$HOME_ROOT/zpause.release" | tail -n 1)"
        fi
        REL_NAME="$n"; REL_VERSION="$v"
        name_of "$HOME_ROOT"
        CH_NAME+=("${REL_NAME:-ZPause}"); CH_VER+=("$REL_VERSION")
        CH_DIR+=("$HOME_ROOT"); CH_SRC+=("$mine"); CH_HERE+=(1)
    fi
    get_library
    if [ "${#LIB_DIR[@]}" -gt 0 ]; then
        for i in "${!LIB_DIR[@]}"; do
            if [ -n "${HOME_ROOT:-}" ] && [ "${LIB_DIR[$i]}" = "$HOME_ROOT" ]; then continue; fi
            CH_NAME+=("${LIB_NAME[$i]}"); CH_VER+=("${LIB_VER[$i]}")
            CH_DIR+=("${LIB_DIR[$i]}"); CH_SRC+=("${LIB_SRC[$i]}"); CH_HERE+=(0)
        done
    fi
    REL_NAME="$_keep_n"; REL_VERSION="$_keep_v"
}

GHV=(); GHU=(); GHN=()
get_releases() {  # get_releases <repo> <asset prefix> -- the whole list
    GHV=(); GHU=(); GHN=()
    net_ready || return 1
    local api json urls u base want v
    api="https://api.github.com/repos/$1/releases?per_page=30"
    if have curl; then json="$(curl -fsL -A ZPause-Manager "$api" 2>/dev/null)"
    elif have wget; then json="$(wget -qO- "$api" 2>/dev/null)"
    else say "Needs curl or wget, and neither is installed."; return 1; fi
    [ -n "$json" ] || { net_problem; return 1; }

    # The version comes off the asset's own name rather than the release
    # tag, which is what lets this stay a grep away from working: the tags
    # and the assets are in one flat list and pairing them up without a JSON
    # parser is guesswork.
    want="$(norm_name "$2")"
    urls="$(printf '%s' "$json" |
        grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' |
        sed 's/.*"\(https[^"]*\)"/\1/')"
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        base="$(basename "$u" | sed 's/%20/ /g; s/%5B/[/g; s/%5D/]/g')"
        case "$base" in *.zip) ;; *) continue ;; esac
        case "$(norm_name "$base")" in "$want"*) ;; *) continue ;; esac
        v="$(printf '%s' "$base" | sed -n 's/.*[ .]v\([0-9][0-9.]*d\?\)[ .].*/\1/p')"
        GHV+=("$v"); GHU+=("$u"); GHN+=("$base")
    done <<< "$urls"
    [ "${#GHU[@]}" -gt 0 ]
}

do_pick_release() {
    which_game || return 0
    blank
    ask "That asks GitHub which releases exist. Go ahead?" y || {
        say "Nothing was contacted."; return 0; }
    ONLINE=1

    head_ "${CAT_NAME[$PICK_IDX]} -- releases on GitHub"
    if ! get_releases "${CAT_REPO[$PICK_IDX]}" "${CAT_ASSET[$PICK_IDX]}"; then
        say "No releases with a download attached."
        return 0
    fi
    blank
    local i c tag
    for i in "${!GHU[@]}"; do
        tag=""
        [ "$i" -eq 0 ] && tag="   latest"
        printf '    %d. v%-10s%s\n' "$((i + 1))" "${GHV[$i]}" "$tag"
    done
    blank
    printf '  which? '
    readl c
    [ -n "$c" ] || return 0
    if ! { [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#GHU[@]}" ] 2>/dev/null; }; then
        say "Not one of the choices."
        return 0
    fi
    i=$((c - 1))
    LATEST_URL="${GHU[$i]}"; LATEST_NAME="${GHN[$i]}"
    LATEST_VERSION="${GHV[$i]}"; LATEST_SIZE=0

    fetch_payload || return 0
    adopt_payload "$FETCHED"
    verify_payload "$ROOT" "$LATEST_VERSION" || return 0
    log "downloaded" "v$REL_VERSION  $FETCHED"
    blank
    ask "Install v$REL_VERSION now?" y && do_install
}

do_versions() {
    head_ "Install a different version"
    get_choices
    local i c where
    if [ "${#CH_SRC[@]}" -eq 0 ]; then
        blank
        say "No ZPause download is on this PC yet."
    else
        blank
        for i in "${!CH_SRC[@]}"; do
            where="kept on this PC"
            [ "${CH_HERE[$i]}" -eq 1 ] && where="came with this installer"
            printf '    %d. %-26s v%-10s %s\n' "$((i + 1))" "${CH_NAME[$i]}" \
                   "${CH_VER[$i]}" "$where"
        done
    fi
    blank
    say "  d. download a different version from GitHub"
    say "     (Enter goes back)"
    blank
    printf '  which? '
    readl c
    [ -n "$c" ] || return 0
    case "$c" in d|D) do_pick_release; return 0 ;; esac
    if ! { [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#CH_SRC[@]}" ] 2>/dev/null; }; then
        say "Not one of the choices."
        return 0
    fi

    # Point the session at that version, then install exactly as normal --
    # upgrading and downgrading are the same operation from here.
    i=$((c - 1))
    ROOT="${CH_DIR[$i]}"
    read_release "$ROOT"
    SRC="${CH_SRC[$i]}"
    do_install
}

do_prune() {
    # Offered once something has been downloaded, and never taken as read:
    # keeping every build is a perfectly good habit.
    [ "$DOWNLOADED" -eq 1 ] || return 0
    get_library
    [ "${#LIB_DIR[@]}" -ge 2 ] || return 0

    head_ "Downloads kept on this PC"
    blank
    local i c tag n=0
    local targets=()
    for i in "${!LIB_DIR[@]}"; do
        tag=""
        if [ -n "${ROOT:-}" ] && [ "${LIB_DIR[$i]}" = "$ROOT" ]; then tag="   just used"; fi
        printf '    %d. %-26s v%-10s%s\n' "$((i + 1))" "${LIB_NAME[$i]}" "${LIB_VER[$i]}" "$tag"
    done
    blank
    say "They are kept on purpose: an older build is worth having if a newer one"
    say "misbehaves, and reinstalling one is two keystrokes from the menu."
    blank
    say "Type a number to delete that download, o for every older one, or press"
    say "Enter to keep them all."
    blank
    printf '  delete: '
    readl c
    [ -n "$c" ] || { say "Kept."; return 0; }

    if [ "$c" = "o" ] || [ "$c" = "O" ]; then
        for i in "${!LIB_DIR[@]}"; do
            if [ -n "${ROOT:-}" ] && [ "${LIB_DIR[$i]}" = "$ROOT" ]; then continue; fi
            targets+=("$i")
        done
    elif [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#LIB_DIR[@]}" ] 2>/dev/null; then
        targets=("$((c - 1))")
    else
        say "Not one of the choices. Nothing deleted."
        return 0
    fi

    if [ "${#targets[@]}" -gt 0 ]; then
        for i in "${targets[@]}"; do
            log "discarded" "v${LIB_VER[$i]}  ${LIB_DIR[$i]}"
            rm -rf "${LIB_DIR[$i]}" "${LIB_ZIP[$i]}" && n=$((n + 1))
        done
    fi
    N_DROPPED=$((N_DROPPED + n))
    blank
    say "Deleted $n download(s). What is installed in the game is untouched."
}

PICK_IDX=-1
pick_game() {
    local i p
    # --yes means "do not ask me anything", so this is the one question it
    # cannot answer for you.
    if [ "$ASSUME_YES" -eq 1 ]; then
        say "Which one? Add --game bundle, or t6 / t5 / t4 / t7 / t8."
        return 1
    fi
    head_ "Which one?"
    blank
    for i in "${!CAT_KEY[@]}"; do
        printf '    %d. %-26s %s\n' "$((i + 1))" "${CAT_NAME[$i]}" "${CAT_WHAT[$i]}"
    done
    blank
    printf '  which? '
    readl p
    if [ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le "${#CAT_KEY[@]}" ] 2>/dev/null; then
        PICK_IDX=$((p - 1)); return 0
    fi
    say "Not one of the choices."
    return 1
}

which_game() {
    local i
    if [ -n "$WANT_GAME" ]; then
        for i in "${!CAT_KEY[@]}"; do
            [ "${CAT_KEY[$i]}" = "$WANT_GAME" ] && { PICK_IDX=$i; return 0; }
        done
        say "No such game: $WANT_GAME"
        return 1
    fi
    if [ -n "$REL_GAME" ]; then
        for i in "${!CAT_KEY[@]}"; do
            [ "${CAT_KEY[$i]}" = "$REL_GAME" ] && { PICK_IDX=$i; return 0; }
        done
    fi
    pick_game
}

FETCHED=""
fetch_payload() {  # uses LATEST_*; sets FETCHED to the unpacked folder
    FETCHED=""
    mkdir -p "$CACHE" 2>/dev/null
    local zip="$CACHE/$LATEST_NAME" out="$CACHE/${LATEST_NAME%.zip}" have_size
    if [ -f "$zip" ]; then
        # One HEAD request rather than a whole download, when the answer is
        # probably "you already have this".
        LATEST_SIZE="$(remote_size "$LATEST_URL")"
        have_size="$(stat -c %s "$zip" 2>/dev/null || echo 0)"
        if [ "$LATEST_SIZE" -gt 0 ] && [ "$have_size" = "$LATEST_SIZE" ]; then
            blank; say "Already downloaded: $LATEST_NAME"
        else
            rm -f "$zip"
        fi
    fi
    if [ ! -f "$zip" ]; then
        blank
        say "Downloading $LATEST_NAME"
        fetch "$LATEST_URL" "$zip" || return 1
    fi

    # When the release publishes checksums, the zip is checked before it is
    # opened. Nothing to do when it does not.
    if [ -n "$LATEST_SUMS" ] && { have sha256sum || have shasum; }; then
        local sf="$CACHE/SHA256SUMS" want="" line
        if fetch "$LATEST_SUMS" "$sf" 1; then
            while IFS= read -r line; do
                case "$line" in [0-9a-f][0-9a-f]*) ;; *) continue ;; esac
                if [ "$(norm_name "${line#* }")" = "$(norm_name "$LATEST_NAME")" ]; then
                    want="${line%% *}"; break
                fi
            done < "$sf"
            if [ -n "$want" ]; then
                if [ "$(file_sha256 "$zip")" = "$want" ]; then
                    say "checksum: the download matches the one published"
                else
                    say "That download does not match the checksum published with it."
                    say "Nothing was installed. Try again, or fetch it by hand."
                    rm -f "$zip"
                    return 1
                fi
            fi
        fi
    fi
    DOWNLOADED=1
    say "Unpacking..."
    unpack "$zip" "$out" || return 1
    FETCHED="$out"
}

adopt_payload() {  # adopt_payload <unpacked folder>
    ROOT="$(root_in "$1")"
    read_release "$ROOT"
    SRC="$(source_of "$ROOT")"
}

# ------------------------------------------------- actions
get_payload() {  # sets SRC, or returns 1
    [ -n "$SRC" ] && { [ -d "$SRC" ] || [ -f "$SRC" ]; } && return 0

    blank
    say "The mod files are not next to this installer."
    blank
    ask "Download them from GitHub?" y || { say "Nothing downloaded."; return 1; }
    ONLINE=1

    which_game || return 1
    head_ "${CAT_NAME[$PICK_IDX]}"
    get_latest "${CAT_REPO[$PICK_IDX]}" "${CAT_ASSET[$PICK_IDX]}" || return 1
    say "latest release: v$LATEST_VERSION"

    fetch_payload || return 1
    adopt_payload "$FETCHED"
    verify_payload "$ROOT" "$LATEST_VERSION" || return 1
    log "downloaded" "v$REL_VERSION  $FETCHED"
    [ -d "$SRC" ] || [ -f "$SRC" ]
}

PLAN_FROM=(); PLAN_TO=()
# Which slots for a game are ticked for install. Every slot is, except
# that Black Ops III's routes are tick boxes (see pick_routes).
PICKED=()
install_plan() {  # install_plan <key> -> PLAN_FROM / PLAN_TO / PLAN_KIND
    PLAN_FROM=(); PLAN_TO=(); PLAN_KIND=()
    local key="$1" i to src f from inTree flat
    for i in "${!SLOT_PATH[@]}"; do
        [ "${SLOT_KEY[$i]}" = "$key" ] || continue
        [ "${PICKED[$i]:-0}" = "1" ] || continue
        to="$(slot_path "$i")" || continue
        if [ "${SLOT_KIND[$i]}" = "folder" ]; then
            src="$(payload_for "$key" folder)" || continue
            for f in "$src"/*; do
                [ -f "$f" ] || continue
                # Only what the mod is made of. A README sitting beside the
                # payload in a source folder is not part of it.
                case "$f" in *.json|*.gscc|*.gsic|*.luac) ;; *) continue ;; esac
                PLAN_FROM+=("$f"); PLAN_TO+=("$to/$(basename "$f")"); PLAN_KIND+=(file)
            done
            PLAN_FROM+=(""); PLAN_TO+=("$to/zpause.installed"); PLAN_KIND+=(stamp)
            continue
        fi
        from="$(payload_for "$key" "${SLOT_KIND[$i]}")" || continue
        [ -n "$from" ] || continue
        # T6's mod-folder copy is a generated variant of the same script,
        # differing only in what zp_origin() returns. A download carries it
        # at its own path already; a source folder has it lying beside the
        # loose one, so pick it up here or the mod slot gets a copy that
        # calls itself the script one.
        case "${SLOT_PATH[$i]}" in
            *mods/zm_pause*)
                inTree="${ROOT:-}/Plutonium/${SLOT_PATH[$i]}"
                flat="$(dirname "$from")/zpause_mod.gsc"
                if [ -f "$inTree" ]; then from="$inTree"
                elif [ -f "$flat" ]; then from="$flat"; fi ;;
        esac
        PLAN_FROM+=("$from"); PLAN_TO+=("$to"); PLAN_KIND+=("${SLOT_KIND[$i]}")
    done
}

PICK_KEY=""
pick_install_game() {  # -> PICK_KEY, from GAMES_HERE, --game, or a question
    PICK_KEY=""
    local k i state mine carry c
    if [ -n "$WANT_GAME" ]; then
        if game_index "$WANT_GAME" >/dev/null; then PICK_KEY="$WANT_GAME"; return 0; fi
        [ "$WANT_GAME" != "bundle" ] && { say "No such game: $WANT_GAME"; return 1; }
    fi
    if [ "${#GAMES_HERE[@]}" -eq 1 ]; then PICK_KEY="${GAMES_HERE[0]}"; return 0; fi
    if [ "$ASSUME_YES" -eq 1 ]; then
        say "Which one? Add --game t6 / t5 / t4 / t7 / t8."
        return 1
    fi
    head_ "Install for which game?"
    blank
    get_installed
    for i in "${!G_KEY[@]}"; do
        k="${G_KEY[$i]}"
        state="not installed"
        for mine in "${!INST_KEY[@]}"; do
            [ "${INST_KEY[$mine]}" = "$k" ] && { state="installed v${INST_VER[$mine]}"; break; }
        done
        carry=""
        case " ${GAMES_HERE[*]-} " in *" $k "*) ;; *) carry="  (not in this download -- would be fetched)" ;; esac
        printf '    %d. %s  %-14s %s%s\n' "$((i + 1))" "${G_TAG[$i]}" "${G_NAME[$i]}" "$state" "$carry"
    done
    blank
    say "     (Enter goes back)"
    blank
    printf '  which? '
    readl c
    [ -n "$c" ] || return 1
    if ! { [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#G_KEY[@]}" ] 2>/dev/null; }; then
        say "Not one of the choices."
        return 1
    fi
    PICK_KEY="${G_KEY[$((c - 1))]}"
}

pick_routes() {  # pick_routes <key> -> PICKED; returns 1 if nothing is ticked
    local key="$1" i box c n any=0
    PICKED=()
    for i in "${!SLOT_PATH[@]}"; do
        [ "${SLOT_KEY[$i]}" = "$key" ] && PICKED[$i]=1
    done
    [ "$key" = "t7" ] || return 0

    # Black Ops III has three loaders, all optional and all independent, so
    # each route is a tick box: found loaders start ticked.
    for i in "${!SLOT_PATH[@]}"; do
        [ "${SLOT_KEY[$i]}" = "$key" ] || continue
        if slot_present "$i"; then PICKED[$i]=1; any=1; else PICKED[$i]=0; fi
    done
    head_ "Where ZPause can go"
    blank
    n=0
    for i in "${!SLOT_PATH[@]}"; do
        [ "${SLOT_KEY[$i]}" = "$key" ] || continue
        n=$((n + 1))
        box="[ ]"; [ "${PICKED[$i]}" = "1" ] && box="[x]"
        printf '    %s %d. %-26s %-10s %s\n' "$box" "$n" "${SLOT_GAME[$i]}" \
               "$(slot_present "$i" && printf installed || printf 'not found')" "${SLOT_NOTE[$i]}"
    done
    if [ "$any" -eq 0 ]; then
        blank
        say "None of the script loaders are installed."
        say "ZPause also ships as a Steam Workshop mod, which needs none of them."
    fi
    blank
    say "Ticked boxes are what was found. Type a number to toggle one,"
    say "or press Enter to install what is ticked."
    blank
    # --yes means the ticks stand as found: there is nobody at the keyboard.
    local slots=()
    for i in "${!SLOT_PATH[@]}"; do [ "${SLOT_KEY[$i]}" = "$key" ] && slots+=("$i"); done
    while [ "$ASSUME_YES" -eq 0 ]; do
        printf '  > '
        readl c
        [ -z "$c" ] && break
        if [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#slots[@]}" ] 2>/dev/null; then
            i="${slots[$((c - 1))]}"
            PICKED[$i]=$((1 - PICKED[$i]))
            box="[ ]"; [ "${PICKED[$i]}" = "1" ] && box="[x]"
            printf '    %s %s\n' "$box" "${SLOT_GAME[$i]}"
        else
            say "Type one of the numbers, or Enter to go ahead."
        fi
    done
    for i in "${slots[@]}"; do [ "${PICKED[$i]}" = "1" ] && return 0; done
    return 1
}

do_install() {  # do_install [1 to skip the confirmation] [key]
    local key="${2:-}" fam root already i n=0 show

    # Nothing beside the installer -- a kept copy, or a bare install.sh.
    # Which game comes first, so the one download is the right one: the
    # generic "download them?" of get_payload would fetch a release and then
    # find it was not the game picked, and fetch again.
    if ! { [ -n "$SRC" ] && { [ -d "$SRC" ] || [ -f "$SRC" ]; }; }; then
        blank
        say "Pick a game and its release is fetched from GitHub."
        games_here
        if [ -z "$key" ]; then pick_install_game || return 0; key="$PICK_KEY"; fi
        fetch_game "$key" || return 0
    fi

    get_payload || return 0
    games_here
    if [ -z "$key" ]; then pick_install_game || return 0; key="$PICK_KEY"; fi
    fam="${GAME_FAM[$key]}"

    # Another game's zip: the files for this one can be fetched.
    case " ${GAMES_HERE[*]-} " in
        *" $key "*) ;;
        *)
            blank
            say "This download has no ${GAME_NAMES[$key]} files in it."
            fetch_game "$key" || return 0
            games_here
            case " ${GAMES_HERE[*]-} " in *" $key "*) ;; *) say "Still nothing to install."; return 0 ;; esac ;;
    esac

    root="$(root_ask "$fam")" || { blank; say "Nothing changed."; return 0; }

    already=""
    get_installed
    for i in "${!INST_KEY[@]}"; do
        [ "${INST_KEY[$i]}" = "$key" ] || continue
        case " $already " in *" ${INST_VER[$i]} "*) ;; *) already="$already ${INST_VER[$i]}" ;; esac
    done
    already="${already# }"
    # Worth reading when it is a change; noise when it is the same build again.
    if [ "$already" != "$REL_VERSION" ]; then
        show_changes "$ROOT" "$REL_VERSION"
        show_default_moves "$key"
    fi

    # Downloads are checked when they arrive; this catches the other way in,
    # which is a zip somebody extracted badly. A source folder has no
    # manifest that describes it, so there is nothing to check.
    if is_download "$ROOT" && ! verify_sums "$ROOT"; then
        blank
        say "Nothing installed. Extract the download again."
        return 0
    fi

    pick_routes "$key" || { blank; say "Nothing ticked. Nothing installed."; return 0; }

    head_ "Installing -- ${GAME_NAMES[$key]}"
    install_plan "$key"
    [ "${#PLAN_TO[@]}" -gt 0 ] || { say "Nothing to install -- no files found for it."; return 0; }

    blank
    for i in "${!PLAN_TO[@]}"; do
        [ "${PLAN_KIND[$i]}" = "stamp" ] && continue
        show="${PLAN_TO[$i]}"
        case "$show" in "$root"/*) show="${show#$root/}" ;; esac
        say "    $show"
    done
    blank
    say "Any existing ZPause file at those paths is replaced -- a copy of it is"
    say "kept first, so it can be put back. Nothing else here is touched."
    blank
    if [ "${1:-0}" != "1" ]; then
        ask "Continue?" y || { blank; say "Cancelled."; return 0; }
    fi

    RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
    BACKUP_N=0
    blank
    for i in "${!PLAN_TO[@]}"; do
        mkdir -p "$(dirname "${PLAN_TO[$i]}")" 2>/dev/null
        if [ "${PLAN_KIND[$i]}" = "stamp" ]; then
            # The mod folder holds compiled files, so nothing in it says
            # which version it is. This does.
            printf '%s\n' "$REL_VERSION" > "${PLAN_TO[$i]}"
            continue
        fi
        backup_file "${PLAN_TO[$i]}"
        if cp -f "${PLAN_FROM[$i]}" "${PLAN_TO[$i]}"; then
            log "installed" "v$REL_VERSION  ${PLAN_TO[$i]}"
            n=$((n + 1))
        else
            say "failed: ${PLAN_TO[$i]}"
        fi
    done
    REF_VER=""; REF_PATH=""

    N_INSTALLED=$((N_INSTALLED + n))
    if [ -n "$REL_VERSION" ]; then
        say "Installed $n file(s) -- v$REL_VERSION."
    else
        say "Installed $n file(s)."
    fi
    reapply_config
    if [ "$fam" = "bo4" ]; then
        say "Only the host needs ZPause. Start a zombies match to load it."
    else
        say "Only the host needs ZPause. End the current match and start a new one"
        say "to load it -- no need to restart the game."
    fi
    if [ "$fam" = "bo3" ] && [ -f "$root/d3d11.dll" ]; then
        blank
        say "You have a community patch installed (T7 Patch or Clean Ops)."
        say "That is fine -- neither is a mod and neither takes the mod slot."
        say "Do not use the t7-compiler injector under one; use a route above."
    fi
    [ "$n" -gt 0 ] && DID_INSTALL=1
    return 0
}

fetch_game() {  # fetch_game <key> -- that game's release, into the cache, adopted
    local key="$1" i idx=""
    for i in "${!CAT_KEY[@]}"; do [ "${CAT_KEY[$i]}" = "$key" ] && idx="$i"; done
    [ -n "$idx" ] || return 1
    ask "Download ${GAME_NAMES[$key]} from GitHub?" y || { say "Nothing downloaded."; return 1; }
    ONLINE=1
    head_ "${CAT_NAME[$idx]}"
    get_latest "${CAT_REPO[$idx]}" "${CAT_ASSET[$idx]}" || return 1
    say "latest release: v$LATEST_VERSION"
    fetch_payload || return 1
    adopt_payload "$FETCHED"
    verify_payload "$ROOT" "$LATEST_VERSION" || return 1
    log "downloaded" "v$REL_VERSION  $FETCHED"
    return 0
}

do_uninstall() {  # do_uninstall [1 to take everything without asking which]
    show_installed
    [ "${#INST_PATH[@]}" -gt 0 ] || return 0
    local c targets=() i n=0 f bo3=0
    if [ "${1:-0}" = "1" ]; then
        # --uninstall --yes takes everything it can find; with --game it
        # takes that game's copies and leaves the rest where they are.
        for i in "${!INST_PATH[@]}"; do
            if [ -n "$WANT_GAME" ] && game_index "$WANT_GAME" >/dev/null 2>&1; then
                [ "${INST_KEY[$i]}" = "$WANT_GAME" ] || continue
            fi
            targets+=("$i")
        done
        if [ "${#targets[@]}" -eq 0 ]; then say "Nothing installed for $WANT_GAME."; return 0; fi
    else
        blank
        say "Type a number to remove that one, or a for all of them."
        say "Only the files ZPause put there are removed -- nothing else, and no folders."
        blank
        printf '  remove: '
        readl c
        [ -n "$c" ] || { say "Cancelled."; return 0; }
        if [ "$c" = "a" ] || [ "$c" = "A" ]; then
            for i in "${!INST_PATH[@]}"; do targets+=("$i"); done
        elif [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#INST_PATH[@]}" ] 2>/dev/null; then
            targets=("$((c - 1))")
        else
            say "Not one of the choices."; return 0
        fi
    fi

    blank
    for i in "${targets[@]}"; do say "${INST_PATH[$i]}"; done
    blank
    ask "Remove these?" || { blank; say "Cancelled."; return 0; }
    RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
    BACKUP_N=0
    for i in "${targets[@]}"; do
        [ "${INST_FAM[$i]}" = "bo3" ] && bo3=1
        if [ "${INST_KIND[$i]}" = "folder" ]; then
            # Files only, and only the ones the mod is made of. The folder
            # stays: it is not ours to delete, and an empty one costs nothing.
            for f in "${INST_PATH[$i]}"/*; do
                [ -f "$f" ] || continue
                case "$f" in *.json|*.gscc|*.gsic|*.luac|*.installed) ;; *) continue ;; esac
                backup_file "$f"
                if rm -f "$f"; then log "removed" "$f"; n=$((n + 1)); fi
            done
            continue
        fi
        backup_file "${INST_PATH[$i]}"
        if rm -f "${INST_PATH[$i]}"; then log "removed" "${INST_PATH[$i]}"; n=$((n + 1))
        else say "failed: ${INST_PATH[$i]}"; fi
    done
    N_REMOVED=$((N_REMOVED + n))
    blank
    say "Removed $n file(s)."
    say "Empty folders are left alone."
    [ "$bo3" -eq 1 ] && say "A Steam Workshop copy is not removed here -- unsubscribe in Steam."
    get_installed
    [ "${#INST_PATH[@]}" -eq 0 ] && DID_INSTALL=0
    return 0
}

do_check() {
    which_game || return 0
    ONLINE=1

    head_ "${CAT_NAME[$PICK_IDX]} -- checking GitHub"
    get_latest "${CAT_REPO[$PICK_IDX]}" "${CAT_ASSET[$PICK_IDX]}" || return 0

    blank
    [ -n "$REL_VERSION" ] && say "you have:  v$REL_VERSION"
    say "latest:    v$LATEST_VERSION"

    if [ -n "$REL_VERSION" ] && [ "$(ver_cmp "$REL_VERSION" "$LATEST_VERSION")" != "-1" ]; then
        blank
        say "You already have the latest release."
        ask "Download it again anyway?" || return 0
    else
        blank
        ask "Download it?" y || { say "Nothing downloaded."; return 0; }
    fi

    fetch_payload || return 0

    adopt_payload "$FETCHED"
    verify_payload "$ROOT" "$LATEST_VERSION" || return 0
    log "downloaded" "v$REL_VERSION  $FETCHED"
    blank
    say "Ready to install v$REL_VERSION"
    update_self "$ROOT"
    ask "Install it now?" y && do_install
}

update_self() {  # update_self <root of a fresh download>
    # The installer improves between releases too. Kept behind its own
    # prompt, because updating the mod and updating the tool that installs
    # it are two different decisions.
    local new="$1/installer/linux/install.sh" mine="$HERE/install.sh" f
    [ -f "$new" ] && [ -f "$mine" ] || return 0
    cmp -s "$new" "$mine" && return 0
    blank
    say "This download also carries a newer copy of this installer."
    ask "Update the installer as well?" y || return 0
    for f in "install.sh" "Install ZPause.desktop"; do
        [ -f "$1/installer/linux/$f" ] && cp -f "$1/installer/linux/$f" "$HERE/$f"
    done
    chmod +x "$HERE/install.sh" 2>/dev/null
    say "Installer updated. It takes effect the next time you run it."
}

make_desktop() {  # make_desktop <path>
    mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
    cat > "$1" <<DESKTOP
[Desktop Entry]
Type=Application
Name=ZPause Manager
Comment=Install, update or remove ZPause
Exec=bash "$STATE/install.sh"
Path=$STATE
Icon=applications-games
Terminal=true
Categories=Game;
DESKTOP
    chmod +x "$1" 2>/dev/null
}

do_persist() {
    if [ -f "$STATE/install.sh" ]; then
        head_ "The kept installer"
        say "$STATE"
        blank
        say "That folder also holds your saved settings, the downloads it kept"
        say "and the backups of files it replaced. All of it goes."
        blank
        ask "Remove it, along with anything it downloaded?" || return 0
        rm -rf "$STATE" "$CACHE"
        rm -f "$HOME/Desktop/ZPause Manager.desktop" \
              "${XDG_DATA_HOME:-$HOME/.local/share}/applications/ZPause Manager.desktop"
        blank
        say "Removed. Your installed ZPause files were not touched."
        return 0
    fi

    head_ "Keep this installer"
    say "A copy goes to:"
    say "  $STATE"
    blank
    say "From there it can fetch any ZPause release by itself, so the folder"
    say "you downloaded is no longer needed."
    blank
    ask "Keep it?" y || return 0

    mkdir -p "$STATE" || { say "Could not create $STATE"; return 0; }
    cp -f "$HERE/install.sh" "$STATE/install.sh" || { say "Could not copy it."; return 0; }
    chmod +x "$STATE/install.sh" 2>/dev/null

    blank
    say "Where would you like a shortcut?"
    blank
    say "    1. Desktop"
    say "    2. Application menu"
    say "    3. both"
    say "    4. neither"
    blank
    printf '  which? '
    local c
    readl c
    case "$c" in
        1|3) make_desktop "$HOME/Desktop/ZPause Manager.desktop" &&
             log "shortcut" "$HOME/Desktop/ZPause Manager.desktop" &&
             say "shortcut: $HOME/Desktop/ZPause Manager.desktop" ;;
    esac
    case "$c" in
        2|3) make_desktop "${XDG_DATA_HOME:-$HOME/.local/share}/applications/ZPause Manager.desktop" &&
             say "shortcut: in your application menu" ;;
    esac
    if [ "$c" = "1" ] || [ "$c" = "3" ]; then
        blank
        say "On a Steam Deck, KDE asks once before it will run a desktop entry:"
        say "right-click it, Properties, Permissions, tick Is executable."
    fi

    blank
    say "Kept. You can delete this download folder whenever you like --"
    say "the kept copy fetches whatever it needs."
}

# ------------------------------------------------- other mods
#
# OTHERMODS.MD in the ZPause repo, if it is there. Plain markdown, so the
# same file reads properly on GitHub and parses here:
#
#     ## Mod Name
#     *2026-09-08 - Xep*
#     What the mod does, in a line or three.
#     https://github.com/Xeptix/ModName
#
# The date and creator line is optional, and so is the link. Anything the
# file does not have is simply not printed.
show_other_mods() {
    # Only ever fetched when you already said yes to talking to GitHub.
    [ "$ONLINE" -eq 1 ] || return 0
    local dest="$CACHE/$OTHER_MODS" branch got=0
    mkdir -p "$CACHE" 2>/dev/null || return 0
    for branch in main master; do
        if fetch "https://raw.githubusercontent.com/$HOME_REPO/$branch/$OTHER_MODS" "$dest" 1; then
            got=1; break
        fi
    done
    # No file in the repo, or no connection: say nothing at all.
    [ "$got" -eq 1 ] && [ -s "$dest" ] || return 0
    grep -qE '^#{2,3} ' "$dest" || return 0

    head_ "Also by Xep"
    local in_comment=0
    local line body seen_head=0 first_after=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        # An HTML comment is how the file documents its own format, so what
        # is inside one is an example and must not become an entry.
        if [ "$in_comment" -eq 1 ]; then
            case "$line" in *'-->'*) in_comment=0 ;; esac
            continue
        fi
        case "$line" in
            '<!--'*)
                case "$line" in *'-->'*) : ;; *) in_comment=1 ;; esac
                continue ;;
        esac
        case "$line" in
            '##'*|'###'*)
                blank
                say "$(printf '%s' "${line#\#\#}" | sed 's/^#*//; s/^ *//; s/[*_`]//g')"
                seen_head=1; first_after=1
                continue ;;
        esac
        [ "$seen_head" -eq 1 ] || continue
        [ -z "$line" ] && continue
        case "$line" in ---*|___*|\*\*\**) continue ;; esac
        # a markdown link or a bare url
        case "$line" in
            \[*\]\(http*)
                say "$(printf '%s' "$line" | sed 's/.*(\(http[^)]*\)).*/\1/')"; continue ;;
            http://*|https://*|'<http'*)
                say "$(printf '%s' "$line" | tr -d '<>')"; continue ;;
        esac
        # the first italic line under a heading is the date and creator
        if [ "$first_after" -eq 1 ] && printf '%s' "$line" | grep -q '^[*_].*[*_]$'; then
            say "$(printf '%s' "$line" | sed 's/^[*_]*//; s/[*_]*$//')"
            first_after=0; continue
        fi
        first_after=0
        say "$(printf '%s' "$line" | sed 's/^[-*+] *//; s/[*_`]//g')"
    done < "$dest"
}

# ------------------------------------------------- telling copies apart
REF_VER=""; REF_PATH=""

first_script() {  # first_script <dir or file>
    [ -n "${1:-}" ] || return 0
    [ -f "$1" ] && { printf '%s' "$1"; return 0; }
    [ -d "$1" ] || return 0
    find "$1" -type f -name '*.gsc' 2>/dev/null | sort | head -n 1
}

# Where a game's files are inside a download or a source folder. A download
# lays each game out as it drops in: Plutonium/storage/<game>, Black Ops
# III/boiii/custom_scripts, t7x/custom_scripts, or a zpause mod folder. A
# source folder has the script flat beside the manifest, under its build
# name. Kind picks which artifact: the text script, the compiled T7x build,
# or the Black Ops 4 mod folder. Prints nothing when this root has none.
payload_in() {  # payload_in <root> <key> <kind>
    local root="${1:-}" key="$2" kind="${3:-file}" one
    [ -n "$root" ] || return 1
    case "$key" in
        t6|t5|t4)
            one="$(first_script "$root/Plutonium/storage/$key")"
            [ -n "$one" ] && { printf '%s' "$one"; return 0; }
            [ "$REL_GAME" = "$key" ] && [ -f "$root/zpause.gsc" ] && { printf '%s' "$root/zpause.gsc"; return 0; }
            ;;
        t7)
            if [ "$kind" = "compiled" ]; then
                [ -f "$root/t7x/custom_scripts/zpause.gsc" ] && { printf '%s' "$root/t7x/custom_scripts/zpause.gsc"; return 0; }
                [ -f "$root/zpause_t7x.gscc" ] && { printf '%s' "$root/zpause_t7x.gscc"; return 0; }
                return 1
            fi
            [ -f "$root/Black Ops III/boiii/custom_scripts/zpause.gsc" ] &&
                { printf '%s' "$root/Black Ops III/boiii/custom_scripts/zpause.gsc"; return 0; }
            [ "$REL_GAME" = "t7" ] && [ -f "$root/zpause.gsc" ] && { printf '%s' "$root/zpause.gsc"; return 0; }
            ;;
        t8)
            [ -f "$root/zpause/metadata.json" ] && { printf '%s' "$root/zpause"; return 0; }
            [ "$REL_GAME" = "t8" ] && [ -f "$root/metadata.json" ] && { printf '%s' "$root"; return 0; }
            ;;
    esac
    return 1
}
payload_for() { payload_in "${ROOT:-}" "$1" "${2:-file}"; }

GAMES_HERE=()
games_here() {  # which of the five this download or source folder carries
    GAMES_HERE=()
    local k
    for k in "${G_KEY[@]}"; do
        if payload_for "$k" file >/dev/null 2>&1; then GAMES_HERE+=("$k"); continue; fi
        [ "$k" = "t8" ] && payload_for t8 folder >/dev/null 2>&1 && GAMES_HERE+=("$k")
    done
}

file_hash() {
    if have sha1sum; then sha1sum "$1" 2>/dev/null | cut -d' ' -f1
    elif have md5sum; then md5sum "$1" 2>/dev/null | cut -d' ' -f1
    elif have cksum; then cksum "$1" 2>/dev/null | cut -d' ' -f1
    fi
}

# Writing settings into an installed script changes its bytes, which would
# otherwise read as "somebody edited this". Recording the hash of what we
# wrote is how the listing tells its own work apart from yours.
mark_applied() {  # mark_applied <path>
    local h tmp
    mkdir -p "$CONFIGDIR" 2>/dev/null || return 0
    h="$(file_hash "$1")"
    [ -n "$h" ] || return 0
    tmp="$APPLIED.tmp"
    { [ -f "$APPLIED" ] && grep -vF "$1|" "$APPLIED"; printf '%s|%s\n' "$1" "$h"; } \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$APPLIED"
}

is_applied() {  # is_applied <path>
    [ -f "$APPLIED" ] || return 1
    local h
    h="$(file_hash "$1")"
    [ -n "$h" ] || return 1
    grep -Fqx "$1|$h" "$APPLIED" 2>/dev/null
}

ref_for() {  # ref_for <version> <key> [kind] -- a known-good copy, if we have one
    # Keyed by game as well as version: inside the bundle every game shares
    # a version, and the first script found was the wrong game's.
    local v="${1:-}" key="${2:-}" kind="${3:-file}" i one ck
    [ -n "$v" ] && [ "$v" != "?" ] || return 0
    ck="$v|$key|$kind"
    if [ "$ck" = "$REF_VER" ]; then printf '%s' "$REF_PATH"; return 0; fi
    REF_VER="$ck"; REF_PATH=""
    get_choices
    if [ "${#CH_DIR[@]}" -gt 0 ]; then
        for i in "${!CH_DIR[@]}"; do
            [ "${CH_VER[$i]}" = "$v" ] || continue
            one="$(payload_in "${CH_DIR[$i]}" "$key" "$kind")" || continue
            [ -n "$one" ] && { REF_PATH="$one"; break; }
        done
    fi
    printf '%s' "$REF_PATH"
}

file_sha256() {
    if have sha256sum; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    elif have shasum; then shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    fi
}

# SHA256SUMS ships inside every download from v1.4 on: one line per file,
# coreutils format, so `sha256sum -c SHA256SUMS` in the extracted folder
# says exactly what this does.
SUMS_OK=0
verify_sums() {  # verify_sums <root> -- 0 = fine, 1 = something does not match
    SUMS_OK=0
    local f="$1/SHA256SUMS" line want rel p got bad=0
    [ -f "$f" ] || return 0
    have sha256sum || have shasum || return 0
    while IFS= read -r line; do
        case "$line" in [0-9a-f][0-9a-f]*) ;; *) continue ;; esac
        want="${line%% *}"
        rel="${line#* }"
        rel="${rel#"${rel%%[! ]*}"}"
        p="$1/$rel"
        if [ ! -f "$p" ]; then
            [ "$bad" -eq 0 ] && say "That download does not match its own checksums:"
            say "    $rel -- missing"; bad=$((bad + 1)); continue
        fi
        got="$(file_sha256 "$p")"
        if [ "$got" != "$want" ]; then
            [ "$bad" -eq 0 ] && say "That download does not match its own checksums:"
            say "    $rel -- does not match"; bad=$((bad + 1)); continue
        fi
        SUMS_OK=$((SUMS_OK + 1))
    done < "$f"
    [ "$bad" -eq 0 ]
}

verify_payload() {  # verify_payload <root> <version it claims>
    # A zip that unpacked short is what this catches: the size check on the
    # cached file cannot see inside it, and half a script installs happily.
    local src k one got have=()
    src="$(source_of "${1:-}")"
    if [ -z "$src" ] || [ ! -e "$src" ]; then
        say "That download has no ZPause files in it."
        return 1
    fi
    for k in "${G_KEY[@]}"; do
        one="$(payload_in "$1" "$k" file)" || one=""
        [ -z "$one" ] && [ "$k" = "t8" ] && { one="$(payload_in "$1" t8 folder)" || one=""; }
        [ -n "$one" ] && have+=("$one")
    done
    if [ "${#have[@]}" -eq 0 ]; then
        say "That download has no zpause script or mod folder in it."
        return 1
    fi
    # The manifest checks every file, which is strictly better than checking
    # the one script; the version check below stays for downloads too old to
    # carry one, and for a source folder, which has no manifest describing it.
    if is_download "$1" && ! verify_sums "$1"; then
        say "Not installing it -- delete it from the cache and try again."
        return 1
    fi
    [ "$SUMS_OK" -gt 0 ] && say "checksums: $SUMS_OK file(s) verified"
    for one in "${have[@]}"; do
        case "$one" in *.gsc) ;; *) continue ;; esac
        got="$(read_version "$one")"
        if [ -n "${2:-}" ] && [ -n "$got" ] && [ "$got" != "?" ] && [ "$got" != "$2" ]; then
            say "That download is labelled v$2 but the script inside says v$got."
            say "Not installing it -- delete it from the cache and try again."
            return 1
        fi
    done
    return 0
}

show_changes() {  # show_changes <root> <version>
    # The README travels with every download, and its changelog section for
    # this version is exactly "what you are about to get" -- which matters
    # most on a downgrade, where it is what you are about to lose.
    local rme base line n=0 inblock=0
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
    rme="$1/README.md"
    [ -f "$rme" ] || return 0
    base="$(printf '%s' "$2" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
    [ -n "$base" ] || return 0
    grep -q "^### v$base\$" "$rme" || return 0
    head_ "What is in v$base"
    blank
    while IFS= read -r line; do
        if [ "$line" = "### v$base" ]; then inblock=1; continue; fi
        # Stop at the next version, or at whatever heading ends the changelog
        # -- a port with only one version listed would otherwise run on.
        case "$line" in '### v'*|'## '*) [ "$inblock" -eq 1 ] && break ;; esac
        [ "$inblock" -eq 1 ] || continue
        [ -z "$line" ] && continue
        case "$line" in ---*) continue ;; esac
        if [ "$n" -ge 18 ]; then say "  ...and more, in the README."; break; fi
        say "$(printf '%s' "$line" | sed 's/\*\*//g; s/`//g')"
        n=$((n + 1))
    done < "$rme"
}

get_installed_versions() {
    get_installed
    [ "${#INST_VER[@]}" -gt 0 ] || return 0
    printf '%s\n' "${INST_VER[@]}" | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# ------------------------------------------------- check my setup
#
# "It is not working" is almost always one of a handful of things, and none
# of them are visible from inside the game. This looks for each of them and
# says which it found.
DOC_BAD=0
doc_ok()   { say "ok    $*"; }
doc_warn() { say "check $*"; DOC_BAD=$((DOC_BAD + 1)); }
doc_note() { say "note  $*"; }

do_doctor() {
    head_ "Check my setup"
    DOC_BAD=0
    get_installed
    blank

    if [ "${#INST_PATH[@]}" -eq 0 ]; then
        doc_warn "ZPause is not installed on this PC at all."
        doc_note "Menu item 1 installs it."
        blank
        return 0
    fi

    local g tag mine vers i raw plain edited=0 known how any fam base json
    for g in "${G_KEY[@]}"; do
        mine=0; vers=""
        for i in "${!INST_KEY[@]}"; do
            [ "${INST_KEY[$i]}" = "$g" ] || continue
            mine=$((mine + 1)); vers="$vers${INST_VER[$i]}
"
        done
        [ "$mine" -gt 0 ] || continue
        tag="${GAME_TAG[$g]}"
        vers="$(printf '%s' "$vers" | sort -u | tr '\n' ' ' | sed 's/ *$//')"
        if [ "$(printf '%s' "$vers" | wc -w)" -gt 1 ]; then
            doc_warn "$tag has copies at different versions: v${vers// /, v}."
            doc_note "      Installing again writes all of them at the same version."
        else
            doc_ok "$tag is installed, v$vers, in $mine place(s)."
        fi

        if [ "$g" = "t6" ]; then
            raw=0; plain=0
            for i in "${!INST_PATH[@]}"; do
                case "${INST_PATH[$i]}" in
                    */raw/scripts/zm/*) raw=1 ;;
                    */storage/t6/scripts/zm/*) plain=1 ;;
                esac
            done
            if [ "$raw" -eq 0 ] || [ "$plain" -eq 0 ]; then
                doc_warn "Only one of the two T6 script paths has ZPause in it."
                doc_note "      Which one your build reads depends on its age, so both should have it."
            fi
            for i in "${!INST_PATH[@]}"; do
                case "${INST_PATH[$i]}" in
                    */mods/zm_pause/*)
                        doc_note "The mod-folder copy is present. It does nothing unless zm_pause is"
                        doc_note "      picked in the in-game Mods menu, and that takes your one mod slot."
                        break ;;
                esac
            done
        fi
    done

    # Files that do not match the version they claim, minus the ones this
    # installer configured itself.
    for i in "${!INST_PATH[@]}"; do
        [ "${INST_VER[$i]}" = "?" ] && doc_warn "Cannot read a version out of ${INST_PATH[$i]}"
        [ "${INST_KIND[$i]}" = "folder" ] && continue
        known="$(ref_for "${INST_VER[$i]}" "${INST_KEY[$i]}" "${INST_KIND[$i]}")"
        if [ -n "$known" ] && ! cmp -s "$known" "${INST_PATH[$i]}" &&
           ! is_applied "${INST_PATH[$i]}"; then
            edited=$((edited + 1))
        fi
    done
    if [ "$edited" -gt 0 ]; then
        doc_warn "$edited installed file(s) do not match the version they claim."
        doc_note "      Something edited them after they were installed. Menu item 1 puts"
        doc_note "      a clean copy back; r puts your own copy back."
    fi

    # A saved config that has not reached the game.
    how="$(apply_how)"
    for g in "${G_KEY[@]}"; do
        [ -f "$(config_file "$g")" ] || continue
        tag="${GAME_TAG[$g]}"
        any=0
        for i in "${!INST_KEY[@]}"; do
            [ "${INST_KEY[$i]}" = "$g" ] && any=1
        done
        [ "$any" -eq 1 ] || continue
        if [ "$g" = "t8" ]; then
            load_config t8
            json="$(json_home)" || json=""
            if [ "${#CFGV[@]}" -gt 0 ] && [ -n "$json" ] && [ ! -f "$json" ]; then
                doc_warn "T8 has saved settings that have not been written for the game to read."
                doc_note "      Open the config editor and save, or install again."
            elif [ "${#CFGV[@]}" -gt 0 ]; then
                doc_ok "T8 settings are written where the game reads them."
            fi
            CFGV=()
            continue
        fi
        if [ "$how" = "cfg" ]; then
            doc_note "$tag has saved settings, exported as a cfg only."
            doc_note "      Nothing was written into the script, so the game needs to exec it."
        else
            any=0
            for i in "${!INST_KEY[@]}"; do
                [ "${INST_KEY[$i]}" = "$g" ] && [ "${INST_KIND[$i]}" = "file" ] &&
                    is_applied "${INST_PATH[$i]}" && any=1
            done
            if [ "$any" -eq 1 ]; then
                doc_ok "$tag settings are in the installed script."
            else
                doc_warn "$tag has saved settings that are not in the installed script."
                doc_note "      Open the config editor and save, or install again."
            fi
        fi
    done

    # The download beside the installer, against its own manifest.
    if is_download "${ROOT:-}" && [ -f "$ROOT/SHA256SUMS" ]; then
        if verify_sums "$ROOT"; then
            doc_ok "The download checks out: $SUMS_OK file(s) match SHA256SUMS."
        else
            doc_warn "The download this installer came from does not match its checksums."
            doc_note "      Extract the zip again, or fetch it again."
        fi
    fi

    # Can it write there at all? One probe per game folder that resolved.
    for fam in pluto bo3 bo4; do
        base="$(root_of "$fam")"
        [ -n "$base" ] || continue
        if touch "$base/.zpause.probe" 2>/dev/null; then
            rm -f "$base/.zpause.probe"
            doc_ok "The ${FAM_LABEL[$fam]} folder is writable."
        else
            doc_warn "The ${FAM_LABEL[$fam]} folder cannot be written to from here."
            doc_note "      Check who owns it, or run this as the user that installed the game."
        fi
    done

    blank
    get_library
    [ "${#LIB_DIR[@]}" -gt 0 ] &&
        doc_note "${#LIB_DIR[@]} download(s) kept, $(fmt_bytes "$(dir_size "$CACHE")")."
    [ -d "$BACKUPS" ] && doc_note "Backups: $(fmt_bytes "$(dir_size "$BACKUPS")")."
    blank
    if [ "$DOC_BAD" -eq 0 ]; then
        say "Nothing looks wrong."
    else
        say "$DOC_BAD thing(s) worth looking at, above."
    fi
}

show_status() {
    # One line that says where you are, so the menu never needs a detour
    # through "what is installed" just to check.
    local state vs bits
    get_installed
    if [ "${#INST_PATH[@]}" -eq 0 ]; then
        state="not installed"
    else
        vs="$(printf '%s\n' "${INST_VER[@]}" | sort -u)"
        if [ "$(printf '%s\n' "$vs" | wc -l)" -eq 1 ]; then
            state="installed v$vs"
        else
            state="installed, mixed versions"
        fi
    fi
    bits="${REL_NAME:-ZPause}  |  $state"
    [ -n "$LATEST_VERSION" ] && bits="$bits  |  latest v$LATEST_VERSION"
    get_library
    [ "${#LIB_DIR[@]}" -gt 0 ] && bits="$bits  |  ${#LIB_DIR[@]} kept"
    say "$bits"
}

dir_size() {
    [ -d "${1:-}" ] || { printf '0'; return 0; }
    local n
    n="$(du -sk "$1" 2>/dev/null | cut -f1)"
    case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$((n * 1024))" ;; esac
}

clear_backups() {  # clear_backups <stamp...> -- newest first
    # Backups accumulate for as long as you keep installing. Same rule as
    # the downloads: nothing goes without being asked, and the newest set
    # stays, because that is the one an accident would need.
    local stamps=("$@") i n=0 tmp
    if [ "${#stamps[@]}" -lt 2 ]; then
        blank
        say "There is only one set, and it is the one worth keeping."
        return 0
    fi
    blank
    ask "Delete all but the newest $((${#stamps[@]} - 1)) set(s)?" || { say "Kept."; return 0; }
    for i in "${!stamps[@]}"; do
        [ "$i" -eq 0 ] && continue
        rm -rf "$BACKUPS/${stamps[$i]}" && n=$((n + 1))
    done
    # The index only describes files that still exist, so prune it too.
    tmp="$BACKUP_INDEX.tmp"
    grep "^${stamps[0]}|" "$BACKUP_INDEX" > "$tmp" 2>/dev/null && mv -f "$tmp" "$BACKUP_INDEX"
    blank
    say "Deleted $n backup set(s)."
}

do_restore() {
    head_ "Put back a file it replaced"
    if [ ! -f "$BACKUP_INDEX" ]; then
        blank
        say "Nothing has been replaced yet, so there is nothing to put back."
        return 0
    fi
    local stamps=() st c i n=0 count vers pick file ver dest
    while IFS= read -r st; do
        [ -n "$st" ] && stamps+=("$st")
    done < <(cut -d'|' -f1 "$BACKUP_INDEX" | sort -ru)
    if [ "${#stamps[@]}" -eq 0 ]; then
        blank; say "Nothing to put back."; return 0
    fi
    blank
    for i in "${!stamps[@]}"; do
        count="$(grep -c "^${stamps[$i]}|" "$BACKUP_INDEX")"
        vers="$(grep "^${stamps[$i]}|" "$BACKUP_INDEX" | cut -d'|' -f3 |
                sort -u | tr '\n' ',' | sed 's/,$//')"
        [ -n "$vers" ] || vers="unknown"
        printf '    %d. %s   %s file(s)   was v%s   %s\n' "$((i + 1))" \
               "$(pretty_stamp "${stamps[$i]}")" "$count" "$vers" \
               "$(fmt_bytes "$(dir_size "$BACKUPS/${stamps[$i]}")")"
    done
    blank
    say "Each of these is what was sitting there before an install replaced it,"
    say "including anything you had edited yourself."
    blank
    say "A number puts that set back. x clears out everything but the newest."
    say "  (Enter goes back)"
    blank
    printf '  which? '
    readl c
    [ -n "$c" ] || return 0
    if [ "$c" = "x" ] || [ "$c" = "X" ]; then clear_backups "${stamps[@]}"; return 0; fi
    if ! { [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#stamps[@]}" ] 2>/dev/null; }; then
        say "Not one of the choices."
        return 0
    fi
    pick="${stamps[$((c - 1))]}"
    blank
    grep "^$pick|" "$BACKUP_INDEX" | cut -d'|' -f4 | while IFS= read -r dest; do say "$dest"; done
    blank
    ask "Put these back?" || { blank; say "Cancelled."; return 0; }
    while IFS='|' read -r st file ver dest; do
        [ "$st" = "$pick" ] || continue
        mkdir -p "$(dirname "$dest")" 2>/dev/null
        if cp -f "$BACKUPS/$st/$file" "$dest" 2>/dev/null; then
            log "restored" "v$ver  $dest"
            n=$((n + 1))
        else
            say "failed: $dest"
        fi
    done < "$BACKUP_INDEX"
    REF_VER=""; REF_PATH=""
    N_RESTORED=$((N_RESTORED + n))
    blank
    say "Put back $n file(s)."
}

# ------------------------------------------------- configuration
#
# Every setting is a dvar of the same name, and the script declares each one
# with its default. That declaration is the source of truth here: names,
# types, defaults, and -- from the "// --- section ---" markers around them
# -- the grouping. All of it travels with the mod, so this works for every
# port and for a bundle download that carries no per-game README.
#
# The README's dvar table supplies the one-line description when it is
# there. release_check.py already forces that table to agree with the
# script, so the two can never drift apart.
CONFIGDIR="$STATE/config"
APPLIED="$CONFIGDIR/applied.txt"
declare -A CFGV=()
declare -A DESCS=()
CFG_DIRTY=0
DV_NAME=(); DV_TYPE=(); DV_DEF=(); DV_SEC=(); DV_DESC=()

# One config per game was enough until it wasn't: a server and a solo game
# want different settings, and so does whoever you send a cfg to. Profiles
# are just named files in a folder per game, so exporting one is still a
# copy of a plain cfg.
profile_name() {  # profile_name <game>
    local p
    p="$(setting "profile_$1")"
    [ -n "$p" ] || p="default"
    printf '%s' "$p"
}

config_dir() {  # config_dir <game>
    local dir="$CONFIGDIR/$1" old="$CONFIGDIR/$1.cfg"
    # v1.4 kept one file per game. Move it in as the default profile.
    if [ -f "$old" ] && [ ! -d "$dir" ]; then
        mkdir -p "$dir" 2>/dev/null && mv -f "$old" "$dir/default.cfg" 2>/dev/null
    fi
    printf '%s' "$dir"
}

config_file() { printf '%s' "$(config_dir "$1")/$(profile_name "$1").cfg"; }

PROF=()
get_profiles() {  # get_profiles <game>
    PROF=()
    local dir f n
    dir="$(config_dir "$1")"
    if [ -d "$dir" ]; then
        for f in "$dir"/*.cfg; do
            [ -f "$f" ] || continue
            n="$(basename "$f" .cfg)"
            PROF+=("$n")
        done
    fi
    case " ${PROF[*]-} " in *" default "*) ;; *) PROF=(default "${PROF[@]-}") ;; esac
    # Drop the empty element an unset array leaves behind.
    local out=() p
    for p in "${PROF[@]-}"; do [ -n "$p" ] && out+=("$p"); done
    PROF=("${out[@]}")
}

do_profiles() {  # do_profiles <game> -- 0 when the active profile changed
    local game="$1" c i n name active f count dir
    while true; do
        head_ "Profiles"
        get_profiles "$game"
        active="$(profile_name "$game")"
        dir="$(config_dir "$game")"
        blank
        for i in "${!PROF[@]}"; do
            f="$dir/${PROF[$i]}.cfg"
            count=0
            [ -f "$f" ] && count="$(grep -c '^ *\(set \)\{0,1\}zp_' "$f" 2>/dev/null || echo 0)"
            if [ "${PROF[$i]}" = "$active" ]; then
                printf '   *%d. %-20s %s setting(s)\n' "$((i + 1))" "${PROF[$i]}" "$count"
            else
                printf '    %d. %-20s %s setting(s)\n' "$((i + 1))" "${PROF[$i]}" "$count"
            fi
        done
        blank
        say "A number switches to that one. n makes a new one from what is open"
        say "now, x deletes one.  (Enter goes back)"
        blank
        printf '  > '
        readl c
        [ -n "$c" ] || return 1

        case "$c" in
            n|N)
                blank
                printf '  name: '
                readl name
                [ -n "$name" ] || continue
                case "$name" in
                    *[!A-Za-z0-9\ _-]*) say "Letters, digits, spaces, dashes and underscores."; continue ;;
                esac
                mkdir -p "$dir" 2>/dev/null
                if cfg_text "$game" > "$dir/$name.cfg"; then
                    set_setting "profile_$game" "$name"
                    say "Made $name and switched to it."
                    return 0
                fi
                say "Could not make it."
                continue ;;
            x|X)
                blank
                printf '  which to delete? '
                readl n
                if ! { [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#PROF[@]}" ] 2>/dev/null; }; then
                    say "Not one of the choices."; continue
                fi
                if [ "${PROF[$((n - 1))]}" = "default" ]; then say "The default one stays."; continue; fi
                ask "Delete ${PROF[$((n - 1))]}?" || continue
                rm -f "$dir/${PROF[$((n - 1))]}.cfg"
                if [ "$active" = "${PROF[$((n - 1))]}" ]; then
                    set_setting "profile_$game" default
                    say "Deleted, and back on default."
                    return 0
                fi
                say "Deleted."
                continue ;;
        esac

        if [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#PROF[@]}" ] 2>/dev/null; then
            [ "${PROF[$((c - 1))]}" = "$active" ] && return 1
            if [ "$CFG_DIRTY" -eq 1 ]; then
                blank
                ask "Save the open one first?" y && save_config "$game"
            fi
            set_setting "profile_$game" "${PROF[$((c - 1))]}"
            say "Now on ${PROF[$((c - 1))]}."
            return 0
        fi
        say "Type a number, n, x, or Enter to go back."
    done
}

show_val() {
    if [ -z "${1:-}" ]; then printf '""'; else printf '%s' "$1"; fi
}

cfg_get() {  # cfg_get <name> <default> -- an explicit "" is a value, not unset
    if [ -n "${CFGV[$1]+x}" ]; then printf '%s' "${CFGV[$1]}"; else printf '%s' "$2"; fi
}

script_for() {  # script_for <game>
    # A pristine text copy first: an installed one may already carry
    # applied settings, and its "defaults" would then be your values.
    # Black Ops 4 has no text script -- its settings come from a manifest.
    local one i
    [ "$1" = "t8" ] && return 1
    one="$(payload_for "$1" file)" && [ -n "$one" ] && { printf '%s' "$one"; return 0; }
    get_choices
    if [ "${#CH_DIR[@]}" -gt 0 ]; then
        for i in "${!CH_DIR[@]}"; do
            one="$(payload_in "${CH_DIR[$i]}" "$1" file)" && [ -n "$one" ] && { printf '%s' "$one"; return 0; }
        done
    fi
    for i in "${!SLOT_PATH[@]}"; do
        [ "${SLOT_KEY[$i]}" = "$1" ] && [ "${SLOT_KIND[$i]}" = "file" ] || continue
        one="$(slot_path "$i")" || continue
        [ -f "$one" ] && { printf '%s' "$one"; return 0; }
    done
    return 1
}

# The list of settings for a game, in one shape whatever it came from.
# Four of the five carry a text script, and the settings are read out of it.
# Black Ops 4 ships compiled, so the build writes zpause.settings beside it
# instead: name|type|default|section|description, one per line, generated
# from the same script. Both end up as the DV_* rows the editor edits.
manifest_for() {  # manifest_for <key>
    local r d
    for r in "${ROOT:-}" "${HOME_ROOT:-}"; do
        [ -n "$r" ] || continue
        [ -f "$r/zpause.settings" ] && { printf '%s' "$r/zpause.settings"; return 0; }
        [ -f "$r/zpause-$1.settings" ] && { printf '%s' "$r/zpause-$1.settings"; return 0; }
    done
    get_choices
    if [ "${#CH_DIR[@]}" -gt 0 ]; then
        for d in "${CH_DIR[@]}"; do
            [ -f "$d/zpause.settings" ] && { printf '%s' "$d/zpause.settings"; return 0; }
            [ -f "$d/zpause-$1.settings" ] && { printf '%s' "$d/zpause-$1.settings"; return 0; }
        done
    fi
    return 1
}

read_manifest() {  # read_manifest <path> -> DV_*
    DV_NAME=(); DV_TYPE=(); DV_DEF=(); DV_SEC=(); DV_DESC=()
    [ -f "${1:-}" ] || return 1
    local line a b c d e seen=" "
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r a b c d e <<< "$line"
        [ -n "$a" ] && [ -n "$b" ] || continue
        case "$seen" in *" $a "*) continue ;; esac
        seen="$seen$a "
        d="$(printf '%s' "$d" | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; print}')"
        DV_NAME+=("$a"); DV_TYPE+=("$b"); DV_DEF+=("$c"); DV_SEC+=("$d"); DV_DESC+=("${e:-}")
    done < "$1"
    [ "${#DV_NAME[@]}" -gt 0 ]
}

dvars_for() {  # dvars_for <game> -> DV_*
    local sp m i line a b c d e
    if [ "$1" = "t8" ]; then
        read_manifest "$(manifest_for t8)"
        return $?
    fi
    sp="$(script_for "$1")" || return 1
    [ -n "$sp" ] || return 1
    read_dvars "$sp" || return 1
    # The script has no descriptions in it. The manifest beside it does,
    # and unlike the README it travels with the game's files -- so this is
    # what keeps the editor readable when it runs from the bundle.
    m="$(manifest_for "$1")" || return 0
    [ -f "$m" ] || return 0
    declare -A _mdesc=()
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r a b c d e <<< "$line"
        [ -n "$a" ] && [ -n "${e:-}" ] && _mdesc[$a]="$e"
    done < "$m"
    for i in "${!DV_NAME[@]}"; do
        [ -z "${DV_DESC[$i]}" ] && [ -n "${_mdesc[${DV_NAME[$i]}]:-}" ] && DV_DESC[$i]="${_mdesc[${DV_NAME[$i]}]}"
    done
    return 0
}

read_dvars() {  # read_dvars <script>
    DV_NAME=(); DV_TYPE=(); DV_DEF=(); DV_SEC=(); DV_DESC=()
    [ -f "${1:-}" ] || return 1
    local line sec="Other" parsed type name def seen=" "
    while IFS= read -r line; do
        case "$line" in
            *'// ---'*)
                sec="$(printf '%s' "$line" |
                       sed -n 's|.*// *--- *\(.*[^ -]\) *---*.*|\1|p')"
                [ -n "$sec" ] || sec="Other"
                sec="$(printf '%s' "$sec" |
                       awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; print}')"
                continue ;;
        esac
        case "$line" in *zp_cfg_*) ;; *) continue ;; esac
        parsed="$(printf '%s' "$line" |
                  sed -n 's/.*zp_cfg_\(int\|float\|str\)( *"\([a-z0-9_]*\)" *, *\(.*\) *).*/\1|\2|\3/p')"
        [ -n "$parsed" ] || continue
        type="${parsed%%|*}"
        name="${parsed#*|}"; name="${name%%|*}"
        def="${parsed##*|}"
        def="${def%"${def##*[![:space:]]}"}"
        if [ "$type" = "str" ]; then def="${def#\"}"; def="${def%\"}"; fi
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        DV_NAME+=("$name"); DV_TYPE+=("$type"); DV_DEF+=("$def")
        DV_SEC+=("$sec"); DV_DESC+=("${DESCS[$name]:-}")
    done < "$1"
    [ "${#DV_NAME[@]}" -gt 0 ]
}

read_descriptions() {
    DESCS=()
    local r line name text
    for r in "${ROOT:-}" "${HOME_ROOT:-}"; do
        [ -n "$r" ] && [ -f "$r/README.md" ] || continue
        while IFS= read -r line; do
            case "$line" in '| `zp_'*) ;; *) continue ;; esac
            name="$(printf '%s' "$line" | sed -n 's/^| *`\(zp_[a-z0-9_]*\)`.*/\1/p')"
            [ -n "$name" ] || continue
            [ -n "${DESCS[$name]:-}" ] && continue
            text="$(printf '%s' "$line" | awk -F'|' '{print $4}' |
                    sed 's/\[\([^]]*\)\]([^)]*)/\1/g; s/[`*]//g; s/^ *//; s/ *$//')"
            DESCS[$name]="$text"
        done < "$r/README.md"
    done
}

declare -A CHOICES=()
read_choices() {  # read_choices <script> -- run after read_dvars
    # What a setting is documented to take. The README backticks each value
    # in the description, which is a good enough source to offer them as a
    # list -- and the script itself is the source for the combos and HUD
    # slots, which the README points at rather than listing.
    CHOICES=()
    local r line name cell tok vals combos slots i add
    for r in "${ROOT:-}" "${HOME_ROOT:-}"; do
        [ -n "$r" ] && [ -f "$r/README.md" ] || continue
        while IFS= read -r line; do
            case "$line" in '| `zp_'*) ;; *) continue ;; esac
            name="$(printf '%s' "$line" | sed -n 's/^| *`\(zp_[a-z0-9_]*\)`.*/\1/p')"
            [ -n "$name" ] || continue
            [ -n "${CHOICES[$name]:-}" ] && continue
            cell="$(printf '%s' "$line" | awk -F'|' '{print $4}')"
            vals=""
            while IFS= read -r tok; do
                [ -n "$tok" ] || continue
                # Values only: not another dvar's name, not a number, not prose.
                case "$tok" in zp_*) continue ;; esac
                case "$tok" in
                    '""') ;;
                    *[!a-z_]*) continue ;;
                esac
                vals="$vals$tok "
            done < <(printf '%s' "$cell" | grep -o '`[^`]*`' | tr -d '`')
            [ -n "$vals" ] && CHOICES[$name]="$vals"
        done < "$r/README.md"
    done

    combos=""; slots=""
    [ -n "${1:-}" ] && [ -f "$1" ] &&
    combos="$(grep -o 'combo == "[a-z_]*"' "$1" 2>/dev/null |
              sed 's/.*"\(.*\)"/\1/' | sort -u | tr '\n' ' ')"
    [ -n "${1:-}" ] && [ -f "$1" ] &&
    slots="$(grep -o 'position == "[a-z]*"' "$1" 2>/dev/null |
             sed 's/.*"\(.*\)"/\1/' | sort -u | tr '\n' ' ')"
    for i in "${!DV_NAME[@]}"; do
        [ "${DV_TYPE[$i]}" = "str" ] || continue
        add=""
        case "${DV_NAME[$i]}" in
            *combo*) add="$combos" ;;
            *position*) add="$slots" ;;
        esac
        [ -n "$add" ] || continue
        CHOICES[${DV_NAME[$i]}]="$(printf '%s %s %s' "${CHOICES[${DV_NAME[$i]}]:-}" "$add" "${DV_DEF[$i]}" |
                                   tr ' ' '\n' | grep -v '^$' | awk '!seen[$0]++' | tr '\n' ' ')"
    done
}

dv_type() {  # dv_type <name>
    local i
    for i in "${!DV_NAME[@]}"; do
        [ "${DV_NAME[$i]}" = "$1" ] && { printf '%s' "${DV_TYPE[$i]}"; return 0; }
    done
    printf 'str'
}

load_config() {  # load_config <game>
    CFGV=()
    local f line name val
    f="$(config_file "$1")"
    [ -f "$f" ] || return 0
    while IFS= read -r line; do
        case "$line" in ''|//*) continue ;; esac
        name="$(printf '%s' "$line" | sed -n 's/^ *\(set \|seta \)\{0,1\}\(zp_[a-z0-9_]*\) .*/\2/p')"
        [ -n "$name" ] || continue
        val="$(printf '%s' "$line" | sed -n 's/^ *\(set \|seta \)\{0,1\}zp_[a-z0-9_]* *\(.*\) *$/\2/p')"
        val="${val%\"}"; val="${val#\"}"
        CFGV[$name]="$val"
    done < "$f"
}

cfg_text() {  # cfg_text <game>
    local i any=0
    printf '// ZPause configuration -- %s  %s\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" "${GAME_NAMES[$1]}"
    printf '// Written by the ZPause Manager. Safe to read, edit, copy and share.\n'
    printf '//\n'
    printf '// Only settings that differ from the default are listed, so this stays\n'
    printf '// short and keeps working when a default changes in a later version.\n'
    printf '//\n'
    printf '// On a dedicated server: exec this file, or paste the lines into your\n'
    printf '// server config.\n\n'
    for i in "${!DV_NAME[@]}"; do
        [ -n "${CFGV[${DV_NAME[$i]}]+x}" ] || continue
        [ "${CFGV[${DV_NAME[$i]}]}" = "${DV_DEF[$i]}" ] && continue
        printf 'set %s "%s"\n' "${DV_NAME[$i]}" "${CFGV[${DV_NAME[$i]}]}"
        any=1
    done
    [ "$any" -eq 0 ] && printf '// (everything is at its default)\n'
    return 0
}

is_compiled() {  # compiled GSC opens with the four bytes 80 47 53 43
    [ -f "$1" ] || return 1
    local magic
    magic="$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "$magic" = "80475343" ]
}

APPLY_SKIPPED=()
apply_to_scripts() {  # apply_to_scripts <game> -- returns the count via APPLIED_N
    # Rewrites the default in each zp_cfg_ call of every installed text copy
    # for this game. Nothing else in the file is touched, and the file it
    # replaces is backed up first like any other write. A compiled copy has
    # no text in it to rewrite; it is reported, not silently skipped.
    APPLIED_N=0
    APPLY_SKIPPED=()
    local i f tmp name val lit
    for i in "${!SLOT_PATH[@]}"; do
        [ "${SLOT_KEY[$i]}" = "$1" ] || continue
        [ "${SLOT_KIND[$i]}" = "folder" ] && continue
        f="$(slot_path "$i")" || continue
        [ -f "$f" ] || continue
        if [ "${SLOT_KIND[$i]}" = "compiled" ] || is_compiled "$f"; then
            APPLY_SKIPPED+=("${SLOT_GAME[$i]}")
            continue
        fi
        tmp="$f.zptmp"
        cp -f "$f" "$tmp" 2>/dev/null || continue
        for name in "${!CFGV[@]}"; do
            val="${CFGV[$name]}"
            case "$val" in *'|'*|*'&'*|*'\'*) continue ;; esac
            lit="$val"
            [ "$(dv_type "$name")" = "str" ] && lit="\"$val\""
            sed -i "s|zp_cfg_\\([a-z]*\\)( *\"$name\" *, *[^)]*)|zp_cfg_\\1( \"$name\", $lit )|" \
                "$tmp" 2>/dev/null
        done
        if cmp -s "$f" "$tmp"; then rm -f "$tmp"; continue; fi
        backup_file "$f"
        if mv -f "$tmp" "$f"; then
            mark_applied "$f"
            log "configured" "$f"
            APPLIED_N=$((APPLIED_N + 1))
        else
            rm -f "$tmp"
        fi
    done
    REF_VER=""; REF_PATH=""
}

apply_how() {
    local h
    h="$(setting config_apply)"
    case "$h" in script|cfg) printf '%s' "$h" ;; *) printf 'both' ;; esac
}

choose_apply() {
    head_ "How should your settings be applied?"
    blank
    say "    1. both -- written into the installed script, and exported as a cfg"
    say "    2. into the installed script only"
    say "    3. exported as a cfg only"
    blank
    say "Writing into the script is what makes settings stick for a normal"
    say "co-op host: Plutonium rewrites its own player cfg, so dvars put there"
    say "do not survive. The exported cfg is the portable one -- exec it on a"
    say "dedicated server, or send it to somebody."
    blank
    printf '  which? '
    local c
    readl c
    case "$c" in
        1) set_setting config_apply both ;;
        2) set_setting config_apply script ;;
        3) set_setting config_apply cfg ;;
        *) say "Left as it was."; return 0 ;;
    esac
    say "Set to: $(apply_how)"
}

# Where the exported cfg goes: beside the game's own scripts, so it is where
# a dedicated server would look for it.
cfg_home() {  # cfg_home <game>
    local r
    case "${GAME_FAM[$1]}" in
        pluto) r="$(root_quiet pluto)" && printf '%s/storage/%s/zpause.cfg' "$r" "$1" ;;
        bo3)   r="$(root_quiet bo3)" && printf '%s/zpause.cfg' "$r" ;;
        bo4)   r="$(root_quiet bo4)" && printf '%s/project-bo4/saved/server/zpause.cfg' "$r" ;;
    esac
}

# Black Ops 4 reads its settings from a JSON file at load: a list of
# { name, value } objects, not one object of pairs, because Shield turns a
# JSON object into a script struct whose fields can only be read by a name
# written into the script, and a list into an array a loop can walk. No
# byte-order mark, LF endings: it is JSON, and the parser wants both.
json_home() {
    local r
    r="$(root_quiet bo4)" || return 1
    printf '%s/project-bo4/saved/server/zpause.json' "$r"
}

write_json_values() {  # -> JSON_N: settings written, 0 if all default, -1 on failure
    JSON_N=-1
    local f dir i name def val lit parts=() n=0
    f="$(json_home)" || return 1
    for i in "${!DV_NAME[@]}"; do
        name="${DV_NAME[$i]}"; def="${DV_DEF[$i]}"
        [ -n "${CFGV[$name]+x}" ] || continue
        val="${CFGV[$name]}"
        [ "$val" = "$def" ] && continue
        if [ "${DV_TYPE[$i]}" = "str" ]; then lit="\"${val//\"/\\\"}\""; else lit="$val"; fi
        parts+=("    { \"name\": \"$name\", \"value\": $lit }")
        n=$((n + 1))
    done
    if [ "$n" -eq 0 ]; then
        # Nothing to say. Removing it is how "everything at default" is
        # expressed, and a file that is not there cannot be half-written.
        if [ -f "$f" ]; then backup_file "$f"; rm -f "$f"; log "removed" "$f"; fi
        JSON_N=0
        return 0
    fi
    dir="$(dirname "$f")"
    mkdir -p "$dir" 2>/dev/null || return 1
    backup_file "$f"
    {
        printf '[\n'
        printf '%s\n' "$(IFS=$',\n'; printf '%s' "${parts[*]}")"
        printf ']\n'
    } > "$f" || return 1
    log "configured" "$f"
    JSON_N="$n"
    return 0
}

# T7x runs a compiled script, so nothing can be written into it. What it
# does have is an exec that reads from disk: its patched Cmd_Exec prefers a
# file under its gamesettings folder, matched on the last two path
# components -- so this is "zpause/zpause.cfg", and that is what the player
# types. Both folders it searches are written, since which exists depends
# on how the client was set up. Its own file rather than an override of a
# stock gamesettings one: the disk copy replaces the fastfile's, and
# zm/gamesettings_zclassic.cfg carries scorelimit, startRound, magic and
# allowdogs. A settings editor should not be able to change how the game
# plays.
t7x_cfg_paths() {
    local r
    [ -n "${APPDATA_T7X:-}" ] && [ -d "$APPDATA_T7X" ] && printf '%s/gamesettings/zpause/zpause.cfg\n' "$APPDATA_T7X"
    r="$(root_quiet bo3)" && [ -d "$r/t7x" ] && printf '%s/t7x/gamesettings/zpause/zpause.cfg\n' "$r"
    return 0
}

write_t7x_cfg() {  # -> T7X_CFG, the first path written
    T7X_CFG=""
    local out dir
    while IFS= read -r out; do
        [ -n "$out" ] || continue
        dir="$(dirname "$out")"
        mkdir -p "$dir" 2>/dev/null || continue
        cfg_text t7 > "$out" 2>/dev/null || continue
        log "exported" "$out"
        [ -z "$T7X_CFG" ] && T7X_CFG="$out"
    done < <(t7x_cfg_paths)
}

apply_values() {  # apply_values <game> [1 to be quiet] -> APPLIED_N
    # The one place that knows how a game takes its settings.
    local quiet="${2:-0}" n
    if [ "$1" = "t8" ]; then
        write_json_values
        APPLIED_N="$JSON_N"
        [ "$APPLIED_N" -lt 0 ] && APPLIED_N=0
        if [ "$quiet" -eq 0 ]; then
            if [ "$JSON_N" -gt 0 ]; then
                say "Written to $(json_home) -- it takes effect on the next match."
            elif [ "$JSON_N" -eq 0 ]; then
                say "Everything is at its default, so no settings file is needed."
            else
                say "Could not write the Black Ops 4 settings file."
            fi
        fi
        return 0
    fi

    apply_to_scripts "$1"
    n="$APPLIED_N"
    if [ "$quiet" -eq 0 ]; then
        if [ "$n" -gt 0 ]; then
            say "Written into $n installed script(s) -- it takes effect on the next pause."
        else
            say "Nothing installed to write it into yet; it will be applied when you install."
        fi
    fi
    if [ "${#APPLY_SKIPPED[@]}" -gt 0 ]; then
        T7X_CFG=""
        [ "$1" = "t7" ] && write_t7x_cfg
        if [ "$quiet" -eq 0 ]; then
            local s
            for s in "${APPLY_SKIPPED[@]}"; do
                say "$s runs a compiled script, so settings cannot be written into it."
            done
            if [ -n "$T7X_CFG" ]; then
                say "Written to $T7X_CFG instead."
                say "In game, open the console and run:"
                say "    exec zpause/zpause.cfg"
                say "Once per session, or bind it. T7x reads cfgs from that folder."
            else
                say "Its settings come from the console."
            fi
        fi
        [ -n "$T7X_CFG" ] && APPLIED_N=$((n + 1))
    fi
    return 0
}

save_config() {  # save_config <game>
    local how out
    how="$(apply_how)"
    # The profile lives a folder deeper than $CONFIGDIR, so create that one.
    mkdir -p "$(config_dir "$1")" 2>/dev/null || { say "Could not create $CONFIGDIR"; return 0; }
    cfg_text "$1" > "$(config_file "$1")" || { say "Could not save."; return 0; }
    blank
    say "Saved to $(config_file "$1")"

    if [ "$how" = "both" ] || [ "$how" = "cfg" ]; then
        out="$(cfg_home "$1")"
        mkdir -p "$(dirname "$out")" 2>/dev/null
        if cfg_text "$1" > "$out"; then
            log "exported" "$out"
            say "Exported to $out"
            say "On a dedicated server, exec that file. It is also the one to share."
        else
            say "Could not export it."
        fi
    fi

    if [ "$how" = "both" ] || [ "$how" = "script" ]; then
        apply_values "$1" 0
    fi
}

reapply_config() {
    # A config set once should survive an update. Called after every install,
    # so a new version never quietly puts you back to the defaults.
    [ "$(apply_how)" = "cfg" ] && return 0
    local g
    for g in "${G_KEY[@]}"; do
        [ -f "$(config_file "$g")" ] || continue
        read_descriptions
        load_config "$g"
        [ "${#CFGV[@]}" -gt 0 ] || continue
        dvars_for "$g" || continue
        apply_values "$g" 1
        [ "$APPLIED_N" -gt 0 ] &&
            say "Put your saved ${GAME_TAG[$g]} settings back, in $APPLIED_N place(s)."
    done
    CFGV=()
    return 0
}

config_game() {  # sets CFG_GAME
    CFG_GAME=""
    local i g c saved mark state k
    if [ -n "$WANT_GAME" ] && game_index "$WANT_GAME" >/dev/null; then CFG_GAME="$WANT_GAME"; return 0; fi
    if [ -n "$REL_GAME" ] && game_index "$REL_GAME" >/dev/null; then CFG_GAME="$REL_GAME"; return 0; fi

    saved="$(setting config_game)"
    head_ "Configure which game?"
    blank
    get_installed
    for i in "${!G_KEY[@]}"; do
        g="${G_KEY[$i]}"
        state="not installed"
        for k in "${!INST_KEY[@]}"; do
            [ "${INST_KEY[$k]}" = "$g" ] && { state="installed v${INST_VER[$k]}"; break; }
        done
        mark=" "
        [ "$saved" = "$g" ] && mark="*"
        printf '   %s%d. %s  %-14s %s\n' "$mark" "$((i + 1))" "${G_TAG[$i]}" "${G_NAME[$i]}" "$state"
    done
    blank
    say "     (Enter goes back)"
    blank
    printf '  which? '
    readl c
    [ -n "$c" ] || return 1
    if ! { [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#G_KEY[@]}" ] 2>/dev/null; }; then
        say "Not one of the choices."
        return 1
    fi
    CFG_GAME="${G_KEY[$((c - 1))]}"
    set_setting config_game "$CFG_GAME"
}

edit_one() {  # edit_one <index into DV_*>
    local i="$1" name type def cur v
    name="${DV_NAME[$i]}"; type="${DV_TYPE[$i]}"; def="${DV_DEF[$i]}"
    cur="$(cfg_get "$name" "$def")"
    blank
    say "$name"
    [ -n "${DV_DESC[$i]}" ] && say "${DV_DESC[$i]}"
    say "now: $(show_val "$cur")    default: $(show_val "$def")"
    blank
    # A setting with a fixed set of values is where a typo does nothing at
    # all in game, silently. Offer the list.
    local picks=() p i=1
    for p in ${CHOICES[$name]:-}; do picks+=("$p"); done
    if [ "${#picks[@]}" -ge 2 ]; then
        blank
        say "It takes one of these:"
        for i in "${!picks[@]}"; do
            if [ "${picks[$i]}" = "$cur" ] || { [ "${picks[$i]}" = '""' ] && [ -z "$cur" ]; }; then
                printf '   -> %d. %s\n' "$((i + 1))" "$(show_val "${picks[$i]}")"
            else
                printf '      %d. %s\n' "$((i + 1))" "$(show_val "${picks[$i]}")"
            fi
        done
    fi

    blank
    if [ "${#picks[@]}" -ge 2 ]; then
        say "Type a number from that list, or a value of your own."
        say "d puts it back to the default; Enter leaves it alone."
    else
        say "Type a new value, d for the default, or Enter to leave it alone."
    fi
    printf '  %s: ' "$name"
    readl v
    [ -n "$v" ] || return 0
    if [ "$v" = "d" ] || [ "$v" = "D" ]; then
        unset "CFGV[$name]"
        CFG_DIRTY=1
        N_SETTINGS=$((N_SETTINGS + 1))
        say "back to the default."
        return 0
    fi
    if [ "${#picks[@]}" -ge 2 ] && [ "$type" = "str" ] &&
       [ "$v" -ge 1 ] 2>/dev/null && [ "$v" -le "${#picks[@]}" ] 2>/dev/null; then
        v="${picks[$((v - 1))]}"
        [ "$v" = '""' ] && v=""
    fi
    v="${v%\"}"; v="${v#\"}"
    case "$type" in
        int)   case "$v" in ''|*[!0-9-]*) say "That one takes a whole number."; return 0 ;; esac ;;
        float) case "$v" in ''|*[!0-9.-]*) say "That one takes a number."; return 0 ;; esac ;;
    esac
    CFGV[$name]="$v"
    CFG_DIRTY=1
    N_SETTINGS=$((N_SETTINGS + 1))
    say "set to $(show_val "$v")"
}

edit_list() {  # edit_list <title> <index...>
    local title="$1"; shift
    local idx=("$@") i c pos cur def
    if [ "${#idx[@]}" -eq 0 ]; then blank; say "Nothing matches."; return 0; fi
    while true; do
        head_ "$title"
        blank
        for i in "${!idx[@]}"; do
            pos="${idx[$i]}"
            def="${DV_DEF[$pos]}"
            cur="$(cfg_get "${DV_NAME[$pos]}" "$def")"
            if [ "$cur" != "$def" ]; then
                printf '   %2d. %-26s %-14s (default %s)\n' "$((i + 1))" \
                       "${DV_NAME[$pos]}" "$(show_val "$cur")" "$(show_val "$def")"
            else
                printf '   %2d. %-26s %s\n' "$((i + 1))" "${DV_NAME[$pos]}" "$(show_val "$cur")"
            fi
            [ -n "${DV_DESC[$pos]}" ] && printf '       %s\n' "${DV_DESC[$pos]}"
        done
        blank
        say "   (a number changes one, Enter goes back)"
        blank
        printf '  > '
        readl c
        [ -n "$c" ] || return 0
        if [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#idx[@]}" ] 2>/dev/null; then
            edit_one "${idx[$((c - 1))]}"
        else
            say "Type one of the numbers, or Enter to go back."
        fi
    done
}

declare -A DEF_TMP=() DEF_OLD=()
defaults_of() {  # defaults_of <script> -- fills DEF_TMP with name -> default
    DEF_TMP=()
    local line parsed type name def
    [ -f "${1:-}" ] || return 1
    while IFS= read -r line; do
        case "$line" in *zp_cfg_*) ;; *) continue ;; esac
        parsed="$(printf '%s' "$line" |
                  sed -n 's/.*zp_cfg_\(int\|float\|str\)( *"\([a-z0-9_]*\)" *, *\(.*\) *).*/\1|\2|\3/p')"
        [ -n "$parsed" ] || continue
        type="${parsed%%|*}"
        name="${parsed#*|}"; name="${name%%|*}"
        def="${parsed##*|}"
        def="${def%"${def##*[![:space:]]}"}"
        if [ "$type" = "str" ]; then def="${def#\"}"; def="${def%\"}"; fi
        DEF_TMP[$name]="$def"
    done < "$1"
}

show_default_moves() {  # show_default_moves <key>
    # A default that changes between versions moves the game under anyone
    # who never set that value. Worth one screen, and only for the settings
    # you are actually leaving to the default.
    local g="$1" new old k moved line
    [ "$g" = "t8" ] && return 0
    new="$(payload_for "$g" file)" || return 0
    [ -n "$new" ] || return 0
    get_installed
    old=""
    for k in "${!INST_KEY[@]}"; do
        [ "${INST_KEY[$k]}" = "$g" ] && [ "${INST_KIND[$k]}" = "file" ] || continue
        old="$(ref_for "${INST_VER[$k]}" "$g" file)"; break
    done
    [ -n "$old" ] && [ "$old" != "$new" ] || return 0

    defaults_of "$old" || return 0
    DEF_OLD=()
    for k in "${!DEF_TMP[@]}"; do DEF_OLD[$k]="${DEF_TMP[$k]}"; done
    defaults_of "$new" || return 0
    load_config "$g"
    moved=""
    for k in "${!DEF_TMP[@]}"; do
        [ -n "${DEF_OLD[$k]+x}" ] || continue
        [ "${DEF_OLD[$k]}" = "${DEF_TMP[$k]}" ] && continue
        [ -n "${CFGV[$k]+x}" ] && continue
        moved="$moved$(printf '  %-26s %s -> %s' "$k" \
               "$(show_val "${DEF_OLD[$k]}")" "$(show_val "${DEF_TMP[$k]}")")
"
    done
    CFGV=()
    [ -n "$moved" ] || return 0
    head_ "${GAME_TAG[$g]} -- defaults that move with this version"
    blank
    say "You are on the default for these, so the update changes them:"
    blank
    printf '%s' "$moved" | while IFS= read -r line; do say "$line"; done
    blank
    say "Set any of them in the config editor to pin it where it is."
}

do_config() {
    config_game || return 0
    local game="$CFG_GAME" sp secs=() sec i c q idx=() total n add p line

    read_descriptions
    if ! dvars_for "$game"; then
        head_ "Configure ZPause"
        blank
        if [ "$game" = "t8" ]; then
            say "No zpause.settings to read the Black Ops 4 settings from."
        else
            say "No $(printf '%s' "$game" | tr '[:lower:]' '[:upper:]') script to read the settings from."
        fi
        say "Install it first, or run this from the download."
        return 0
    fi
    sp="$(script_for "$game")" || sp=""
    read_choices "$sp"
    load_config "$game"
    CFG_DIRTY=0

    while true; do
        head_ "Configure ZPause -- $(printf '%s' "$game" | tr '[:lower:]' '[:upper:]')  ${GAME_NAMES[$game]}  [$(profile_name "$game")]"
        secs=()
        for i in "${!DV_SEC[@]}"; do
            case " ${secs[*]-} " in *" ${DV_SEC[$i]} "*) ;; *) secs+=("${DV_SEC[$i]}") ;; esac
        done
        total=0
        for i in "${!DV_NAME[@]}"; do
            [ "$(cfg_get "${DV_NAME[$i]}" "${DV_DEF[$i]}")" != "${DV_DEF[$i]}" ] && total=$((total + 1))
        done
        blank
        for i in "${!secs[@]}"; do
            n=0; c=0
            for p in "${!DV_NAME[@]}"; do
                [ "${DV_SEC[$p]}" = "${secs[$i]}" ] || continue
                n=$((n + 1))
                [ "$(cfg_get "${DV_NAME[$p]}" "${DV_DEF[$p]}")" != "${DV_DEF[$p]}" ] && c=$((c + 1))
            done
            if [ "$c" -gt 0 ]; then
                printf '    %d. %-20s %2d settings   %d changed\n' "$((i + 1))" "${secs[$i]}" "$n" "$c"
            else
                printf '    %d. %-20s %2d settings\n' "$((i + 1))" "${secs[$i]}" "$n"
            fi
        done
        blank
        [ "$total" -gt 0 ] && say "$total setting(s) differ from the defaults."
        [ "$CFG_DIRTY" -eq 1 ] && say "Unsaved -- w writes and applies them."
        say "applying: $(apply_how)"
        blank
        say "  /  find a setting by name  (or just type the name)"
        say "  p  profiles"
        say "  w  save and apply"
        say "  e  export a copy somewhere else"
        say "  i  import a config file"
        say "  m  change how settings are applied"
        say "  x  put everything back to the defaults"
        say "     (Enter goes back)"
        blank
        printf '  > '
        readl c

        if [ -z "$c" ]; then
            if [ "$CFG_DIRTY" -eq 1 ]; then
                blank
                ask "Save your changes first?" y && save_config "$game"
            fi
            return 0
        fi

        if [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "${#secs[@]}" ] 2>/dev/null; then
            sec="${secs[$((c - 1))]}"
            idx=()
            for i in "${!DV_NAME[@]}"; do
                [ "${DV_SEC[$i]}" = "$sec" ] && idx+=("$i")
            done
            edit_list "$sec" "${idx[@]}"
            continue
        fi

        # Typing a setting's name goes straight to it, with or without the
        # prefix, because that is what anyone who knows the name will try.
        for i in "${!DV_NAME[@]}"; do
            if [ "${DV_NAME[$i]}" = "$c" ] || [ "${DV_NAME[$i]}" = "zp_$c" ]; then
                edit_one "$i"
                continue 2
            fi
        done

        case "$c" in
            p|P)
                if do_profiles "$game"; then
                    load_config "$game"
                    CFG_DIRTY=0
                fi ;;
            /)
                blank
                printf '  find: '
                readl q
                if [ -n "$q" ]; then
                    idx=()
                    for i in "${!DV_NAME[@]}"; do
                        case "${DV_NAME[$i]}${DV_DESC[$i]}" in
                            *"$q"*) idx+=("$i") ;;
                        esac
                    done
                    edit_list "Matching '$q'" "${idx[@]-}"
                fi ;;
            w) save_config "$game"; CFG_DIRTY=0 ;;
            e)
                blank
                say "Where should the copy go? Paste a folder or a full file path."
                printf '  path: '
                readl p
                p="${p%\"}"; p="${p#\"}"; p="${p/#\~/$HOME}"
                if [ -n "$p" ]; then
                    [ -d "$p" ] && p="$p/zpause-$game.cfg"
                    if cfg_text "$game" > "$p" 2>/dev/null; then
                        log "exported" "$p"
                        say "Written to $p"
                    else
                        say "Could not write it."
                    fi
                fi ;;
            i)
                blank
                say "Paste the path of a zpause cfg to read in."
                printf '  path: '
                readl p
                p="${p%\"}"; p="${p#\"}"; p="${p/#\~/$HOME}"
                if [ -n "$p" ] && [ -f "$p" ]; then
                    add=0
                    while IFS= read -r line; do
                        case "$line" in ''|//*) continue ;; esac
                        q="$(printf '%s' "$line" | sed -n 's/^ *\(set \|seta \)\{0,1\}\(zp_[a-z0-9_]*\) .*/\2/p')"
                        [ -n "$q" ] || continue
                        n="$(printf '%s' "$line" | sed -n 's/^ *\(set \|seta \)\{0,1\}zp_[a-z0-9_]* *\(.*\) *$/\2/p')"
                        n="${n%\"}"; n="${n#\"}"
                        CFGV[$q]="$n"
                        add=$((add + 1))
                    done < "$p"
                    CFG_DIRTY=1
                    say "Read $add setting(s). Nothing is written until you save."
                elif [ -n "$p" ]; then
                    say "No such file."
                fi ;;
            m) choose_apply ;;
            x)
                blank
                if ask "Put every setting back to its default?"; then
                    CFGV=()
                    CFG_DIRTY=1
                    say "All back to the defaults. Save to apply it."
                fi ;;
            *) say "Type a section number, or one of the letters." ;;
        esac
    done
}

farewell() {
    do_prune
    show_other_mods
    blank
    # What this run actually did, in one line, because a long session
    # scrolls the answer off the top.
    local did=""
    add_did() { if [ -z "$did" ]; then did="$1"; else did="$did, $1"; fi; }
    [ "$N_INSTALLED" -gt 0 ] && add_did "installed $N_INSTALLED file(s) at v$REL_VERSION"
    [ "$N_REMOVED" -gt 0 ] && add_did "removed $N_REMOVED"
    [ "$N_RESTORED" -gt 0 ] && add_did "put back $N_RESTORED"
    [ "$N_SETTINGS" -gt 0 ] && add_did "changed $N_SETTINGS setting(s)"
    [ "$N_DROPPED" -gt 0 ] && add_did "deleted $N_DROPPED download(s)"
    [ -n "$did" ] && say "This run: $did."
    if [ "$DID_INSTALL" -eq 1 ]; then
        say "ZPause is installed. Have fun."
    else
        say "Nothing left to do."
    fi
    blank
}

# ------------------------------------------------- menu

# ---- one thing, then stop --------------------------------------------
# So a support answer can be a line somebody pastes rather than a list of
# keys to press, and so a shortcut can be wired to a plain install.
if [ "$DO_INSTALL" -eq 1 ] || [ "$DO_UNINSTALL" -eq 1 ] || [ "$DO_LIST" -eq 1 ] || [ "$DO_CONFIGURE" -eq 1 ]; then
    if [ "$DO_UNINSTALL" -eq 1 ]; then do_uninstall 1
    elif [ "$DO_LIST" -eq 1 ]; then show_installed
    elif [ "$DO_CONFIGURE" -eq 1 ]; then do_config
    else
        _k=""
        game_index "$REL_GAME" >/dev/null 2>&1 && _k="$REL_GAME"
        do_install 0 "$_k"
    fi
    blank
    exit 0
fi

show_installed

# ---- the common case, in one keystroke -------------------------------
# Most runs are somebody who downloaded the zip and wants it installed.
# That should not start with a menu.
if [ -n "$SRC" ] && { [ -d "$SRC" ] || [ -f "$SRC" ]; } && [ -n "$REL_VERSION" ] &&
   [ "$(get_installed_versions)" != "$REL_VERSION" ]; then
    blank
    say "Ready to install ${REL_NAME:-ZPause} v$REL_VERSION."
    say "Press Enter to go ahead, or m for the menu."
    blank
    printf '  > '
    readl go
    case "$go" in
        ""|y*|Y*)
            _k=""
            game_index "$REL_GAME" >/dev/null 2>&1 && _k="$REL_GAME"
            do_install 1 "$_k" ;;
    esac
fi

# Asked once, up front, and never assumed: answer no and this script makes
# no network connection of any kind.
blank
ask "Check GitHub for a newer version?" && do_check

while true; do
    blank
    show_status
    blank
    say "  1  install or update ZPause here"
    say "  2  what is installed"
    say "  3  install a different version"
    say "  4  configure ZPause"
    say "  5  remove ZPause"
    say "  6  check GitHub for the latest version"
    if [ -f "$STATE/install.sh" ]; then
        say "  7  remove the kept installer"
    else
        say "  7  keep this installer on this PC"
    fi
    say "  d  check my setup"
    [ -f "$BACKUP_INDEX" ] && say "  r  put back a file it replaced"
    say "  p  use a different game folder"
    say "  q  quit"
    blank
    printf '  > '
    readl choice
    case "$choice" in
        1) do_install 0 ;;
        2) show_installed
           if [ "${#INST_PATH[@]}" -gt 0 ]; then
               blank
               say "Item 3 installs a different version; item 4 changes its settings."
           fi ;;
        3) do_versions ;;
        4) do_config ;;
        5) do_uninstall 0 ;;
        6) do_check ;;
        7) do_persist ;;
        d|D) do_doctor ;;
        r|R) do_restore ;;
        p|P)
            head_ "Which game folder?"
            blank
            _fams=(pluto bo3 bo4)
            for _i in "${!_fams[@]}"; do
                _cur="$(root_of "${_fams[$_i]}")"; [ -n "$_cur" ] || _cur="(not set)"
                printf '    %d. %-14s %s\n' "$((_i + 1))" "${FAM_LABEL[${_fams[$_i]}]}" "$_cur"
            done
            blank
            printf '  which? '
            readl _c
            if [ "$_c" -ge 1 ] 2>/dev/null && [ "$_c" -le 3 ] 2>/dev/null; then
                _fam="${_fams[$((_c - 1))]}"
                find_roots "$_fam"
                if choose_root "$_fam" 1; then
                    ROOTS[$_fam]="$CHOSEN"
                    [ "$_fam" = "pluto" ] && PLUTO="$CHOSEN"
                    set_setting "$_fam" "$CHOSEN"
                    head_ "${FAM_LABEL[$_fam]}"; say "$CHOSEN"
                    show_installed
                fi
            fi ;;
        q|Q) farewell; exit 0 ;;
        "") ;;
        *) say "Type one of the numbers, or q to quit." ;;
    esac
done
