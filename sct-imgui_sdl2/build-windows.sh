#!/usr/bin/env bash
# build-windows.sh - SCT Template (imgui + SDL2) builder only from Windows
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
# As of 30/10/2026 standard msys2 provides SDL2 but not imgui!
# I manually packaged imgui for my mingw32 and mingw64
#
# The script NEVER installs anything. Missing tools/packages are listed with
# the pacman command you would have to run yourself, then it exits non-zero.
set -euo pipefail
cd "$(dirname "$0")"

echo " #######################################################################"
echo " #                                                                     #"
echo " #   -=[       SCT Template Windows Builder : imgui + sdl2       ]=-   #"
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
            rm -rf "build/$a"
            echo "cleaned build/$a"
        done
    else
        rm -rf build
        echo "cleaned build/"
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

for a in "${ARCHS[@]}"; do
    P="$MSYS_ROOT/$(prefix_of "$a")"
    plat=$(plat_of "$a")
    echo "-- $a ($P)"

    for tool in gcc g++ windres strip; do
        [[ -x $P/bin/$tool.exe ]] || miss "$P/bin/$tool.exe" \
            "mingw-w64-$(case $a in win-x64) echo x86_64;; win-x86) echo i686;; esac)-$tool (gcc toolchain)"
    done
    [[ -x $P/bin/pkg-config.exe ]] || miss "$P/bin/pkg-config.exe" \
        "pkg-config for $(prefix_of "$a") (mingw-w64-$(case $a in win-x64) echo x86_64;; win-x86) echo i686;; esac)-pkg-config)"

    need_file "prebuilt/libxmp-lite/$plat/lib/libxmp-lite.a" \
        "prebuilt libxmp-lite static lib for $plat (ships in the repo)"
    need_file "prebuilt/libxmp-lite/$plat/include/libxmp-lite/xmp.h" \
        "prebuilt libxmp-lite header for $plat (ships in the repo)"
    need_file "src/sct.rc"  "src/sct.rc - Windows icon resource"

    if [[ -x $P/bin/pkg-config.exe ]]; then
        for m in sdl2 imgui_impl_sdl2 imgui_impl_opengl3; do
            if ! "$P/bin/pkg-config.exe" --exists "$m" 2>/dev/null; then
                miss "$P pkg-config module: $m" \
                    "imgui static package for $(prefix_of "$a") (build temp/mingw-w64-imgui, then pacman -U)"
            elif ! "$P/bin/pkg-config.exe" --static --libs "$m" >/dev/null 2>&1; then
                miss "$P pkg-config --static --libs $m" "static .pc data for '$m'"
            fi
        done
    fi
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

echo "Preflight OK: all tools, headers, libs and pkg-config modules present."
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

CWARN_C="-Wall -Wextra -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes"
CWARN_CXX="-Wall -Wextra -Wshadow -Wformat=2 -Wold-style-cast -Wuseless-cast"

"$PYTHON" src/assets_gen.py

build_arch() {
    local a=$1
    local P="$MSYS_ROOT/$(prefix_of "$a")"
    local plat
    plat=$(plat_of "$a")
    local out=build/$a
    mkdir -p "$out"

    # gcc's driver needs its own bin dir on PATH to spawn cc1 with its DLLs
    export PATH="/$(prefix_of "$a")/bin:$PATH"

    local cflags libs
    cflags=$("$P/bin/pkg-config.exe" --cflags sdl2 imgui_impl_sdl2 imgui_impl_opengl3)
    libs=$("$P/bin/pkg-config.exe" --static --libs sdl2 imgui_impl_sdl2 imgui_impl_opengl3)

    echo "== compiling ($a)"
    for f in banner xmplayer assets; do
        "$P/bin/gcc.exe" -std=c11 $OPT -fno-ident -DLIBXMP_STATIC $CWARN_C \
            -c "src/$f.c" -o "$out/$f.o" \
            -Isrc -isystem "prebuilt/libxmp-lite/$plat/include/libxmp-lite" \
            $cflags
    done
    for f in main ui; do
        "$P/bin/g++.exe" -std=c++17 $OPT -fno-ident $CWARN_CXX \
            -c "src/$f.cpp" -o "$out/$f.o" -Isrc $cflags
    done
    "$P/bin/windres.exe" src/sct.rc -O coff -o "$out/sct_res.o"

    echo "== linking $out/$PROJ.exe"
    local strip_flag=""
    [[ $STRIP == 1 ]] && strip_flag="-s"
    "$P/bin/g++.exe" $strip_flag -o "$out/$PROJ.exe" "$out"/*.o \
        "prebuilt/libxmp-lite/$plat/lib/libxmp-lite.a" \
        $libs -static -mwindows
    if [[ $STRIP == 1 ]]; then
        "$P/bin/strip.exe" --strip-all "$out/$PROJ.exe"
        "$PYTHON" src/scrub_ident.py "$out/$PROJ.exe" >/dev/null
    fi
    echo "   -> $out/$PROJ.exe"
}

for a in "${ARCHS[@]}"; do
    echo "#######################################################################"
    echo "## building sct (imgui + sdl2) for $a ($(label_of "$a"))"
    echo "#######################################################################"
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
