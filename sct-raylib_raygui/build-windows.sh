#!/usr/bin/env bash
# build-windows.sh - SCT Template (raylib + raygui) builder only from Windows
# (x86|x64).
#
#   ./build-windows.sh                # interactive: pick x32 / x64 / both
#   ./build-windows.sh win-x64        # non-interactive
#   ./build-windows.sh win-x86
#   ./build-windows.sh clean [win-x64|win-x86]   # remove artifacts
#   ./build-windows.sh both --dry-run # checks only, no compiling
#   ./build-windows.sh debug [targets] # -O0 -g, no strip, no scrub
#   BUILD=debug ./build-windows.sh    # same as the debug argument
#
# IMPORTANT
#
# Runs inside any MSYS2 shell (mingw32 / mingw64 / msys). The toolchains are
# taken from <msys2-root>/mingw64 and <msys2-root>/mingw32, so both
# architectures build from one shell.
#
# IMPORTANT
#
# raylib is built from source with the mingw-w64 cmake of each subsystem; it
# needs mingw-w64-x86_64-cmake / mingw-w64-i686-cmake (each pulls its ninja)
# and the raylib 6.0 sources cloned into third_party/raylib.
#
# The script NEVER installs anything. Missing tools/packages are listed with
# the pacman command you would have to run yourself, then it exits non-zero.
set -euo pipefail
cd "$(dirname "$0")"

echo " #######################################################################"
echo " #                                                                     #"
echo " #   -=[     SCT Template Windows Builder : raylib + raygui      ]=-   #"
echo " #     _______ _______ _______                                         #"
echo " #    |    ...|    ...|    ...|  Author : Blue DeviL                   #"
echo " #    |  _____|    .__|_   .._|                                        #"
echo " #    | |_____|   .|    |  .|    Date   : 05/11/2026                   #"
echo " #    |_____.:|   :|    |  :|    WEB    : github.com/blue-devil        #"
echo " #     _____|:|   :|__  |  :|                                          #"
echo " #    |    .::|   .:::| |  :|  --/   Freedom, doesn't come from   \--  #"
echo " #    |_______|_______| |___|  --\_     second-hand thoughts.    _/--  #"
echo " #                                                                     #"
echo " #######################################################################"
echo ""

PROJ=sct

usage() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# -----------------------------------------------------------------------------
# arguments
# -----------------------------------------------------------------------------
DRY=0
ARCH_ARG=""

if [[ ${1:-} == clean ]]; then
    shift
    if [[ $# -gt 0 ]]; then
        for a in "$@"; do
            case $a in win-x64|win-x86) ;; *) echo "unknown target $a"; exit 1 ;; esac
            rm -rf "build/$a" "build/raylib-$a"
            echo "cleaned build/$a (and build/raylib-$a)"
        done
    else
        rm -rf build
        echo "cleaned build/ (incl. raylib builds)"
    fi
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        win-x64|win-x86|both) ARCH_ARG=$1 ;;
        debug) BUILD=debug ;;
        --dry-run) DRY=1 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1"; usage ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# target definitions
# -----------------------------------------------------------------------------
prefix_of() { case $1 in win-x64) echo mingw64 ;; win-x86) echo mingw32 ;; esac; }
plat_of()   { case $1 in win-x64) echo windows-x64 ;; win-x86) echo windows-x86 ;; esac; }
label_of()  { case $1 in win-x64) echo "Windows x64 (x86_64)" ;; win-x86) echo "Windows x32 (i686)" ;; esac; }

# -----------------------------------------------------------------------------
# interactive select
# -----------------------------------------------------------------------------
if [[ -z $ARCH_ARG ]]; then
    echo " Build what?"
    echo "   1) both  (x32 + x64)"
    echo "   2) win-x64"
    echo "   3) win-x86"
    read -r -p " [1] > " choice
    case ${choice:-1} in
        1) ARCH_ARG=both ;;
        2) ARCH_ARG=win-x64 ;;
        3) ARCH_ARG=win-x86 ;;
        *) echo "invalid choice"; exit 1 ;;
    esac
fi

case $ARCH_ARG in
    both) ARCHS=(win-x64 win-x86) ;;
    *)    ARCHS=("$ARCH_ARG") ;;
esac

# -----------------------------------------------------------------------------
# preflight
# -----------------------------------------------------------------------------
MSYS_ROOT=$(cygpath -m / 2>/dev/null || echo "C:/msys64")
MISSING=()
HINTS=()
miss() { MISSING+=("$1"); HINTS+=("$2"); }

need_cmd()  { command -v "$1" >/dev/null 2>&1 || miss "$1" "$2"; }
need_file() { [[ -e $1 ]] || miss "$1" "$2"; }

echo "-----------------------------------------------------------------------"
echo " Preflight (targets: ${ARCHS[*]} | msys2 root: $MSYS_ROOT)"
echo "-----------------------------------------------------------------------"

need_cmd bash "bash - you are already running it"
PYTHON=""
for p in python python3; do
    if command -v "$p" >/dev/null 2>&1; then PYTHON=$p; break; fi
done
[[ -n $PYTHON ]] || miss "python" "python - regenerates the embedded assets (assets_gen.py)"
command -v file >/dev/null 2>&1 || true   # report only, not required
[[ -d third_party/raylib/src ]] || miss "third_party/raylib" \
    "raylib 6.0 sources: git clone --depth 1 --branch 6.0 https://github.com/raysan5/raylib third_party/raylib"

for a in "${ARCHS[@]}"; do
    P="$MSYS_ROOT/$(prefix_of "$a")"
    plat=$(plat_of "$a")
    echo "-- $a ($P)"

    for tool in gcc windres strip; do
        [[ -x $P/bin/$tool.exe ]] || miss "$P/bin/$tool.exe" \
            "mingw-w64-$(case $a in win-x64) echo x86_64;; win-x86) echo i686;; esac)-$tool (gcc toolchain)"
    done
    [[ -x $P/bin/cmake.exe ]] || miss "$P/bin/cmake.exe" \
        "mingw-w64-$(case $a in win-x64) echo x86_64;; win-x86) echo i686;; esac)-cmake (builds raylib)"
    if [[ ! -x $P/bin/ninja.exe && ! -x $P/bin/mingw32-make.exe ]]; then
        miss "$P/bin/ninja.exe" "build backend for cmake (pulled in by the mingw-w64-*-cmake package)"
    fi

    need_file "prebuilt/libxmp-lite/$plat/lib/libxmp-lite.a" \
        "prebuilt libxmp-lite static lib for $plat (ships in the repo)"
    need_file "prebuilt/libxmp-lite/$plat/include/libxmp-lite/xmp.h" \
        "prebuilt libxmp-lite header for $plat (ships in the repo)"
    need_file "src/sct.rc"  "src/sct.rc - Windows icon resource"
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    echo "-----------------------------------------------------------------------"
    echo " MISSING REQUIREMENTS (${#MISSING[@]}) - nothing was installed by me"
    echo "-----------------------------------------------------------------------"
    for i in "${!MISSING[@]}"; do
        printf '  [missing] %-52s %s\n' "${MISSING[$i]}" "${HINTS[$i]}"
    done
    echo ""
    echo "Suggested manual fix (run it yourself, this script never will):"
    declare -A pkgs=()
    for i in "${!MISSING[@]}"; do
        h=${HINTS[$i]}
        if [[ $h == mingw-w64-* ]]; then
            p=${h%% *}
            pkgs[$p]=1
        fi
    done
    [[ ${#pkgs[@]} -gt 0 ]] && echo "  pacman -S ${!pkgs[*]}"
    exit 2
fi

echo "Preflight OK: all tools, headers, libs and raylib sources present."
echo ""

if [[ $DRY == 1 ]]; then
    echo "-- dry run: would execute, in this order:"
    for a in "${ARCHS[@]}"; do
        printf '  %s ->  build/%s/%s.exe\n' "$a" "$a" "$PROJ"
    done
    echo "Dry run finished, nothing was compiled."
    exit 0
fi

# -----------------------------------------------------------------------------
# building
# -----------------------------------------------------------------------------
if [[ ${BUILD:-release} == debug ]]; then
    OPT="-O0 -g"
    STRIP=0
else
    OPT="-O2 -DNDEBUG"
    STRIP=1
fi

CWARN="-Wall -Wextra -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes"

RAYLIB_SRC="$PWD/third_party/raylib"
WINDOWS_LIBS="-mwindows -lopengl32 -lgdi32 -lwinmm -lws2_32"

"$PYTHON" src/assets_gen.py

build_raylib() { # arch (native cmake of the subsystem, no toolchain file)
    local a=$1
    local P="$MSYS_ROOT/$(prefix_of "$a")"
    local b=build/raylib-$a
    if [[ -f $b/done ]]; then echo "== raylib $a (cached)"; return; fi
    echo "== raylib $a"
    rm -rf "$b" && mkdir -p "$b"
    # gcc's driver needs its own bin dir on PATH to spawn cc1 with its DLLs
    export PATH="/$(prefix_of "$a")/bin:$PATH"
    (cd "$b" && "$P/bin/cmake.exe" "$RAYLIB_SRC" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-fno-ident \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_GAMES=OFF \
        >/dev/null && "$P/bin/cmake.exe" --build . >/dev/null)
    touch "$b/done"
}

build_arch() {
    local a=$1
    local P="$MSYS_ROOT/$(prefix_of "$a")"
    local plat
    plat=$(plat_of "$a")
    local out=build/$a
    mkdir -p "$out"
    export PATH="/$(prefix_of "$a")/bin:$PATH"

    local raylib_a
    raylib_a=$(find build/raylib-$a -name 'libraylib.a' | head -1)
    [[ -n $raylib_a ]] || { echo "libraylib.a not found for $a"; exit 1; }

    echo "== compiling ($a)"
    # Strict warnings for our sources; third_party is -isystem so warnings
    # inside raylib.h/raygui.h are not reported against our code.
    for f in main banner xmplayer sct_textbox assets; do
        "$P/bin/gcc.exe" -std=c11 $OPT -fno-ident -DLIBXMP_STATIC $CWARN \
            -c "src/$f.c" -o "$out/$f.o" \
            -Isrc -isystem third_party -isystem third_party/raylib/src \
            -isystem "prebuilt/libxmp-lite/$plat/include/libxmp-lite"
    done
    "$P/bin/windres.exe" src/sct.rc -O coff -o "$out/sct_res.o"

    echo "== linking $out/$PROJ.exe"
    # -s strips at link time; the subsystem strip then drops anything left.
    # .comment stays: it carries the SCT build tag; the GCC version note in
    # it is blanked by scrub_ident.py.
    local strip_flag=""
    [[ $STRIP == 1 ]] && strip_flag="-s"
    "$P/bin/gcc.exe" $strip_flag -o "$out/$PROJ.exe" "$out"/*.o \
        "prebuilt/libxmp-lite/$plat/lib/libxmp-lite.a" "$raylib_a" $WINDOWS_LIBS
    if [[ $STRIP == 1 ]]; then
        "$P/bin/strip.exe" --strip-all "$out/$PROJ.exe"
        "$PYTHON" src/scrub_ident.py "$out/$PROJ.exe" >/dev/null
    fi
    echo "   -> $out/$PROJ.exe"
}

for a in "${ARCHS[@]}"; do
    echo "#######################################################################"
    echo "## building sct (raylib + raygui) for $a ($(label_of "$a"))"
    echo "#######################################################################"
    build_raylib "$a"
    build_arch "$a"
done

echo ""
echo "-----------------------------------------------------------------------"
echo " Artifacts"
echo "-----------------------------------------------------------------------"
rc=0
for a in "${ARCHS[@]}"; do
    exe="build/$a/$PROJ.exe"
    if [[ -f $exe ]]; then
        info=""
        command -v file >/dev/null 2>&1 && info="  [$(file -b "$exe" | cut -c1-60)]"
        printf '  %-30s %8d bytes%s\n' "$exe" "$(stat -c %s "$exe")" "$info"
    else
        echo "  MISSING: $exe"
        rc=1
    fi
done
echo ""
[[ $rc == 0 ]] && echo "all done." || echo "finished with errors."
exit $rc
