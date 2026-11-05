#!/usr/bin/env bash
# build.sh - SCT Template (raylib + raygui) builder only from Linux machine
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
#   ./build.sh clean          # remove all artifacts (build/, incl. raylib)
#   ./build.sh clean win-x64  # remove artifacts of one target
#
# raylib is built from source (third_party/raylib, clone at release 6.0) per
# target with cmake, then linked statically together with libxmp-lite and
# raygui (header-only). Release binaries are stripped and scrubbed (no
# symtab/debug, no GCC idents, no home paths). The .comment build tag
# survives: strip --strip-all keeps the section and scrub_ident.py only
# blanks GCC version strings and home paths.
set -euo pipefail
cd "$(dirname "$0")"

echo " #######################################################################"
echo " #                                                                     #"
echo " #   -=[         SCT Template Builder : raylib + raygui          ]=-   #"
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
SCT Template (raylib + raygui) builder - usage:

  ./build.sh                 build every target whose toolchain is present
                             (missing ones are listed and skipped)
  ./build.sh debug [targets]  debug build (-O0 -g, no strip, no scrub)
  ./build.sh clean           remove all artifacts (build/, incl. raylib)
  ./build.sh clean <target>  remove artifacts of one target
  ./build.sh -h | --help     this help

targets:
  aarch64   Linux aarch64 (native)
  x64       Linux x86_64 (cross)
  x86       Linux i686 (cross)
  win-x64   Windows x64 (mingw cross)
  win-x86   Windows i686 (mingw cross)

one-time setup:
  git clone --depth 1 --branch 6.0 https://github.com/raysan5/raylib third_party/raylib

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
            rm -rf "build/$t" "build/raylib-$t"
            echo "cleaned build/$t (and build/raylib-$t)"
        done
    else
        rm -rf build
        echo "cleaned build/ (incl. raylib builds)"
    fi
    exit 0
fi

PROJ=sct

CWARN="-Wall -Wextra -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes"

if [[ ${BUILD:-release} == debug ]]; then
    OPT="-O0 -g"
    STRIP=0
else
    OPT="-O2 -DNDEBUG"
    STRIP=1
fi

RAYLIB_SRC="$PWD/third_party/raylib"
JOBS=$(nproc)

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
# or the script fails. Nothing is ever installed or cloned.
# -----------------------------------------------------------------------------
EXPLICIT=$#
TARGETS=("$@")
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(aarch64 x64 x86 win-x64 win-x86)

BUILDABLE=()
SKIPPED=()

echo "-----------------------------------------------------------------------"
echo " Preflight (targets: ${TARGETS[*]})"
echo "-----------------------------------------------------------------------"

for req in python3 cmake make; do
    if ! command -v "$req" >/dev/null 2>&1; then
        echo "  [missing] $req - build requirement of this template"
        exit 2
    fi
done
if [[ ! -d "$RAYLIB_SRC/src" ]]; then
    echo "  [missing] third_party/raylib - raylib 6.0 sources"
    echo "            git clone --depth 1 --branch 6.0 https://github.com/raysan5/raylib third_party/raylib"
    exit 2
fi

for t in "${TARGETS[@]}"; do
    triple=$(target_triple "$t")
    plat=$(target_plat "$t")
    MISSING=()
    HINTS=()
    miss() { MISSING+=("$1"); HINTS+=("$2"); }

    if [[ $t == aarch64 ]]; then
        command -v gcc >/dev/null 2>&1 || miss "gcc" "native C compiler (gcc)"
        command -v g++ >/dev/null 2>&1 || miss "g++" "native C++ compiler (cmake checks for it)"
    else
        tools="gcc g++"
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

# write_toolchain <file> <system_name> <processor> <compiler> <root> [rc]
write_toolchain() {
    cat > "$1" <<EOF
set(CMAKE_SYSTEM_NAME $2)
set(CMAKE_SYSTEM_PROCESSOR $3)
set(CMAKE_C_COMPILER $4)
set(CMAKE_CXX_COMPILER ${4%%gcc}g++)
${6:+set(CMAKE_RC_COMPILER $6)}
set(CMAKE_FIND_ROOT_PATH $5)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
}

build_raylib() { # name [toolchain]
    local name=$1 tc=${2:-} tcabs=""
    [[ -n $tc ]] && tcabs="$PWD/$tc"
    local b=build/raylib-$name
    if [[ -f $b/done ]]; then echo "== raylib $name (cached)"; return; fi
    echo "== raylib $name"
    rm -rf "$b" && mkdir -p "$b"
    (cd "$b" && cmake "$RAYLIB_SRC" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-fno-ident \
        ${tcabs:+-DCMAKE_TOOLCHAIN_FILE="$tcabs"} \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_GAMES=OFF \
        >/dev/null && cmake --build . -j"$JOBS" >/dev/null)
    touch "$b/done"
}

build_app() { # name cc plat syslibs exe
    local name=$1 cc=$2 plat=$3 syslibs=$4 exe=$5
    echo "== app $name ($cc)"
    local out=build/$name lib raylib_a
    mkdir -p "$out"
    raylib_a=$(find build/raylib-$name -name 'libraylib.a' | head -1)
    [[ -n $raylib_a ]] || { echo "libraylib.a not found for $name"; exit 1; }
    # Strict warnings for our sources; third_party is -isystem so warnings
    # inside raylib.h/raygui.h are not reported against our code.
    for f in main banner xmplayer sct_textbox assets; do
        "$cc" -std=c11 $OPT -fno-ident -DLIBXMP_STATIC $CWARN -c "src/$f.c" -o "$out/$f.o" \
            -Isrc -isystem third_party -isystem third_party/raylib/src \
            -isystem "prebuilt/libxmp-lite/$plat/include/libxmp-lite"
    done
    # Binutils prefix: "x86_64-w64-mingw32-gcc" -> "x86_64-w64-mingw32-", "cc" -> "".
    local prefix=""
    [[ $cc == *-gcc ]] && prefix="${cc%gcc}"
    # Windows: compile src/sct.rc (GLFW_ICON) so title bar, taskbar and Explorer
    # show the icon. The .o lands in $out and is linked by the *.o glob below.
    if [[ $exe == ".exe" ]]; then
        "${prefix}windres" src/sct.rc -O coff -o "$out/sct_res.o"
    fi
    # -s strips at link time; the target's own strip (host strip can't read x86
    # ELF or PE) then drops anything left. .comment stays: it carries the SCT
    # build tag; the GCC version note in it is blanked by scrub_ident.py.
    local link=("$cc" -o "$out/$PROJ$exe" "$out"/*.o \
        "prebuilt/libxmp-lite/$plat/lib/libxmp-lite.a" "$raylib_a" $syslibs)
    if [[ $STRIP == 1 ]]; then
        "${link[@]}" -s
        "${prefix}strip" --strip-all "$out/$PROJ$exe"
        # mingw crt/libgcc "GCC: (GNU) x.y.z" idents get merged into .rdata,
        # where strip can't reach them; blank them in place (unreferenced
        # bytes).
        python3 src/scrub_ident.py "$out/$PROJ$exe" >/dev/null
    else
        "${link[@]}"
    fi
    echo "   -> $out/$PROJ$exe"
}

LINUX_LIBS="-lGL -lX11 -lXrandr -lXinerama -lXcursor -lXi -ldl -lpthread -lrt -lm"
# -mwindows: GUI subsystem, so Explorer launches don't open a console window
WINDOWS_LIBS="-mwindows -lopengl32 -lgdi32 -lwinmm -lws2_32"

mkdir -p build
write_toolchain build/tc-x64.cmake  Linux  x86_64  x86_64-linux-gnu-gcc /usr/x86_64-linux-gnu
write_toolchain build/tc-x86.cmake  Linux  i686    i686-linux-gnu-gcc   /usr/i686-linux-gnu
write_toolchain build/tc-wx64.cmake Windows AMD64   x86_64-w64-mingw32-gcc /usr/x86_64-w64-mingw32 x86_64-w64-mingw32-windres
write_toolchain build/tc-wx86.cmake Windows X86     i686-w64-mingw32-gcc   /usr/i686-w64-mingw32     i686-w64-mingw32-windres

for t in "${TARGETS[@]}"; do
    triple=$(target_triple "$t")
    echo "#######################################################################"
    echo "## building sct (raylib + raygui) for $t ($(target_label "$t"))"
    echo "#######################################################################"
    case $t in
        aarch64)
            build_raylib aarch64
            build_app aarch64 cc linux-aarch64 "$LINUX_LIBS" "" ;;
        x64)
            build_raylib x64 build/tc-x64.cmake
            build_app x64 x86_64-linux-gnu-gcc linux-x64 "$LINUX_LIBS" "" ;;
        x86)
            build_raylib x86 build/tc-x86.cmake
            build_app x86 i686-linux-gnu-gcc linux-x86 "$LINUX_LIBS" "" ;;
        win-x64)
            build_raylib win-x64 build/tc-wx64.cmake
            build_app win-x64 x86_64-w64-mingw32-gcc windows-x64 "$WINDOWS_LIBS" ".exe" ;;
        win-x86)
            build_raylib win-x86 build/tc-wx86.cmake
            build_app win-x86 i686-w64-mingw32-gcc windows-x86 "$WINDOWS_LIBS" ".exe" ;;
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
