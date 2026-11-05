#!/usr/bin/env bash
# build.sh - SCT Template (imgui + SDL2) builder only from Linux machine
# (aarch64). Default run builds every target whose toolchain is present and
# warns about the missing ones:
#   aarch64         Linux aarch64 (native)
#   x64             Linux x86_64 (cross)
#   x86             Linux i686 (cross)
#   win-x64         Windows x64 (mingw cross)
#   win-x86         Windows i686 (mingw cross)
#
#   ./build.sh                # all targets (default)
#   ./build.sh win-x64        # one target
#   ./build.sh x64 win-x86    # any subset
#   ./build.sh clean          # remove all artifacts (build/)
#   ./build.sh clean win-x64  # remove artifacts of one target
#
# Windows exes link fully statically (-static, pkg-config --static): SDL2,
# the Dear ImGui backends, libxmp-lite and the C++ runtime are baked in,
# they run on their own with just the Windows system DLLs.
#
# Release binaries are stripped and scrubbed (no symtab/debug, no GCC idents,
# no home paths), like the sct-raylib_raygui project. The .comment build tag
# survives: strip --strip-all keeps the section and scrub_ident.py only
# blanks GCC version strings and home paths.
set -euo pipefail
cd "$(dirname "$0")"

echo " #######################################################################"
echo " #                                                                     #"
echo " #   -=[           SCT Template Builder : imgui + sdl2           ]=-   #"
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

usage() {
    cat <<'EOF'
SCT Template (imgui + SDL2) builder - usage:

  ./build.sh                 build every target whose toolchain is present
                             (missing ones are listed and skipped)
  ./build.sh debug [targets]  debug build (-O0 -g, no strip, no scrub)
  ./build.sh clean           remove all artifacts (build/)
  ./build.sh clean <target>  remove artifacts of one target
  ./build.sh -h | --help     this help

targets:
  aarch64   Linux aarch64 (native)
  x64       Linux x86_64 (cross)
  x86       Linux i686 (cross)
  win-x64   Windows x64 (mingw cross)
  win-x86   Windows i686 (mingw cross)

environment:
  BUILD=debug ./build.sh     same as the debug argument
EOF
    exit "${1:-0}"
}

case ${1:-} in
    -h|--help) usage 0 ;;
esac

ARGS=()
for arg in "$@"; do
    case $arg in
        debug) BUILD=debug ;;
        aarch64|x64|x86|win-x64|win-x86|clean) ARGS+=("$arg") ;;
        *) echo "unknown argument: $arg"; echo ""; usage 1 ;;
    esac
done
set -- "${ARGS[@]}"

# -----------------------------------------------------------------------------
# clean
# -----------------------------------------------------------------------------
if [[ ${1:-} == clean ]]; then
    shift
    if [[ $# -gt 0 ]]; then
        for t in "$@"; do
            case $t in
                aarch64|x64|x86|win-x64|win-x86) ;;
                *) echo "unknown target $t"; exit 1 ;;
            esac
            rm -rf "build/$t"
            echo "cleaned build/$t"
        done
    else
        rm -rf build
        echo "cleaned build/"
    fi
    exit 0
fi

PROJ=sct

CWARN_C="-Wall -Wextra -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes"
CWARN_CXX="-Wall -Wextra -Wshadow -Wformat=2 -Wold-style-cast -Wuseless-cast"

if [[ ${BUILD:-release} == debug ]]; then
    OPT="-O0 -g"
    STRIP=0
else
    OPT="-O2 -DNDEBUG"
    STRIP=1
fi

PKGS="sdl2 imgui_impl_sdl2 imgui_impl_opengl3"

target_triple() {
    case $1 in
        aarch64) echo "" ;;
        x64)     echo x86_64-linux-gnu ;;
        x86)     echo i686-linux-gnu ;;
        win-x64) echo x86_64-w64-mingw32 ;;
        win-x86) echo i686-w64-mingw32 ;;
    esac
}

target_plat() {
    case $1 in
        aarch64) echo linux-aarch64 ;;
        x64)     echo linux-x64 ;;
        x86)     echo linux-x86 ;;
        win-x64) echo windows-x64 ;;
        win-x86) echo windows-x86 ;;
    esac
}

target_label() {
    case $1 in
        aarch64) echo "Linux aarch64 (native)" ;;
        x64)     echo "Linux x64 (x86_64 cross)" ;;
        x86)     echo "Linux x86 (i686 cross)" ;;
        win-x64) echo "Windows x64 (x86_64 mingw)" ;;
        win-x86) echo "Windows x86 (i686 mingw)" ;;
    esac
}

# -----------------------------------------------------------------------------
# preflight
#
# Default run (no arguments): warns about targets whose toolchain is
# missing and builds the rest. Explicitly named targets must be buildable
# or the script fails. Nothing is ever installed.
# -----------------------------------------------------------------------------
EXPLICIT=$#
TARGETS=("$@")
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(aarch64 x64 x86 win-x64 win-x86)

BUILDABLE=()
SKIPPED=()

echo "-----------------------------------------------------------------------"
echo " Preflight (targets: ${TARGETS[*]})"
echo "-----------------------------------------------------------------------"

if ! command -v python3 >/dev/null 2>&1; then
    echo "  [missing] python3 - regenerates the embedded assets (assets_gen.py)"
    exit 2
fi

for t in "${TARGETS[@]}"; do
    triple=$(target_triple "$t")
    plat=$(target_plat "$t")
    MISSING=()
    HINTS=()
    miss() { MISSING+=("$1"); HINTS+=("$2"); }

    if [[ $t == aarch64 ]]; then
        command -v g++ >/dev/null 2>&1 || miss "g++" "native C++ compiler (g++)"
        command -v pkg-config >/dev/null 2>&1 || miss "pkg-config" "pkg-config"
    else
        tools="gcc g++ pkg-config"
        [[ $t == win-* ]] && tools="$tools windres strip"
        for tool in $tools; do
            command -v "${triple}-${tool}" >/dev/null 2>&1 || \
                miss "${triple}-${tool}" "${triple}-${tool} (cross toolchain)"
        done
    fi

    [[ -f prebuilt/libxmp-lite/$plat/lib/libxmp-lite.a ]] || \
        miss "prebuilt/libxmp-lite/$plat/lib/libxmp-lite.a" "prebuilt libxmp-lite for $plat (ships in the repo)"
    [[ -f prebuilt/libxmp-lite/$plat/include/libxmp-lite/xmp.h ]] || \
        miss "prebuilt/libxmp-lite/$plat/include/libxmp-lite/xmp.h" "prebuilt libxmp-lite header for $plat"
    [[ $t == win-* && ! -f src/sct.rc ]] && miss "src/sct.rc" "src/sct.rc - Windows icon resource"

    pc_cmd="pkg-config"
    [[ $t != aarch64 ]] && pc_cmd="${triple}-pkg-config"
    if command -v "$pc_cmd" >/dev/null 2>&1; then
        for m in $PKGS; do
            if ! "$pc_cmd" --exists "$m" 2>/dev/null; then
                miss "$pc_cmd module: $m" \
                    "static package providing '$m' for $t (sdl2 + imgui)"
            elif ! "$pc_cmd" --static --libs "$m" >/dev/null 2>&1; then
                miss "$pc_cmd --static --libs $m" "static .pc data for '$m'"
            fi
        done
    fi

    if [[ ${#MISSING[@]} -eq 0 ]]; then
        echo "-- $t ($(target_label "$t")): OK"
        BUILDABLE+=("$t")
        continue
    fi

    if [[ $EXPLICIT -gt 0 ]]; then
        echo "-- $t ($(target_label "$t")):"
        for i in "${!MISSING[@]}"; do
            printf '  [missing] %-52s %s\n' "${MISSING[$i]}" "${HINTS[$i]}"
        done
        echo ""
        echo "Target '$t' was requested explicitly and cannot be built here."
        echo "Nothing was installed by me."
        exit 2
    fi

    echo "-- $t ($(target_label "$t")): SKIPPED, missing ${#MISSING[@]} requirement(s)"
    for i in "${!MISSING[@]}"; do
        printf '  [missing] %-52s %s\n' "${MISSING[$i]}" "${HINTS[$i]}"
    done
    SKIPPED+=("$t")
done

if [[ ${#BUILDABLE[@]} -eq 0 ]]; then
    echo ""
    echo "No buildable target on this machine. Nothing was installed by me."
    exit 2
fi
TARGETS=("${BUILDABLE[@]}")
echo ""
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "WARNING: skipped ${SKIPPED[*]} - toolchain/libraries missing (see above)."
fi
echo "Preflight OK: building ${TARGETS[*]}"
echo ""

# -----------------------------------------------------------------------------
# building
# -----------------------------------------------------------------------------
python3 src/assets_gen.py

# build_app <name> <cxx> <pkgcfg> <plat> <exe> [extra_ldflags]
build_app() {
    local name=$1 cxx=$2 pkg=$3 plat=$4 exe=$5 extra=$6
    echo "== app $name ($cxx)"
    local out=build/$name
    mkdir -p "$out"

    local prefix=""
    [[ $cxx == *-g++ ]] && prefix="${cxx%g++}"

    # package cflags used as-is: the -I paths sit inside the system prefix,
    # and marking them -isystem breaks the cross C++ stdlib (include_next).
    # imgui/SDL headers are warning-clean under our $CWARN set (imgui's
    # casts are silenced with pragmas at the include sites in our sources).
    local cflags libs
    cflags=$("$pkg" --cflags $PKGS)
    libs=$("$pkg" --static --libs $PKGS)

    # C sources (banner/xmplayer need SDL headers; assets is data only)
    local cc=${prefix}gcc
    [[ -z $prefix ]] && cc=cc
    for f in banner xmplayer assets; do
        $cc -std=c11 $OPT -fno-ident -DLIBXMP_STATIC $CWARN_C -c "src/$f.c" -o "$out/$f.o" \
            -Isrc -isystem "prebuilt/libxmp-lite/$plat/include/libxmp-lite" $cflags
    done

    # C++ sources
    for f in main ui; do
        $cxx -std=c++17 $OPT -fno-ident $CWARN_CXX -c "src/$f.cpp" -o "$out/$f.o" \
            -Isrc $cflags
    done

    # Windows: icon resource + GUI subsystem
    if [[ $exe == ".exe" ]]; then
        "${prefix}windres" src/sct.rc -O coff -o "$out/sct_res.o"
    fi

    local link=("$cxx" -o "$out/$PROJ$exe" "$out"/*.o \
        "prebuilt/libxmp-lite/$plat/lib/libxmp-lite.a" $libs)
    if [[ $STRIP == 1 ]]; then
        "${link[@]}" -s $extra
        if [[ -n $prefix ]]; then
            "${prefix}strip" --strip-all "$out/$PROJ$exe"
        else
            strip --strip-all "$out/$PROJ$exe"
        fi
        python3 src/scrub_ident.py "$out/$PROJ$exe" >/dev/null
    else
        "${link[@]}" $extra
    fi
    echo "   -> $out/$PROJ$exe"
}

for t in "${TARGETS[@]}"; do
    triple=$(target_triple "$t")
    echo "#######################################################################"
    echo "## building sct (imgui + sdl2) for $t ($(target_label "$t"))"
    echo "#######################################################################"
    case $t in
        aarch64)
            build_app aarch64 g++ pkg-config linux-aarch64 "" "-lGL -lm -ldl -lpthread" ;;
        x64)
            build_app x64 x86_64-linux-gnu-g++ x86_64-linux-gnu-pkg-config linux-x64 "" "-lGL -lm -ldl -lpthread" ;;
        x86)
            build_app x86 i686-linux-gnu-g++ i686-linux-gnu-pkg-config linux-x86 "" "-lGL -lm -ldl -lpthread" ;;
        win-x64)
            build_app win-x64 x86_64-w64-mingw32-g++ x86_64-w64-mingw32-pkg-config windows-x64 ".exe" "-static -mwindows" ;;
        win-x86)
            build_app win-x86 i686-w64-mingw32-g++ i686-w64-mingw32-pkg-config windows-x86 ".exe" "-static -mwindows" ;;
        *)
            echo "unknown target $t"; exit 1 ;;
    esac
done

echo ""
echo "-----------------------------------------------------------------------"
echo " Artifacts"
echo "-----------------------------------------------------------------------"
rc=0
for t in "${TARGETS[@]}"; do
    exe="build/$t/$PROJ$( [[ $t == win-* ]] && echo '.exe' )"
    if [[ -f $exe ]]; then
        info=""
        command -v file >/dev/null 2>&1 && info="  [$(file -b "$exe" | cut -c1-60)]"
        printf '  %-24s %8d bytes%s\n' "$exe" "$(stat -c %s "$exe")" "$info"
    else
        echo "  MISSING: $exe"
        rc=1
    fi
done
echo ""
[[ $rc == 0 ]] && echo "all done." || echo "finished with errors."
exit $rc
