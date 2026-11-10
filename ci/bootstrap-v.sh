#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/toolchain.env"
destination=${1:-.tools/v}

checkout() {
    repository=$1
    revision=$2
    directory=$3
    if [ -e "$directory" ]; then
        printf 'Compiler destination already exists: %s\n' "$directory" >&2
        exit 1
    fi
    git init -q "$directory"
    git -C "$directory" remote add origin "$repository"
    git -C "$directory" fetch --depth 1 origin "$revision"
    git -C "$directory" checkout -q --detach FETCH_HEAD
    test "$(git -C "$directory" rev-parse HEAD)" = "$revision"
}

checkout "$V_REPOSITORY" "$V_REVISION" "$destination"
checkout "$VC_REPOSITORY" "$VC_REVISION" "$destination/vc"
cd "$destination"

case "$(uname -s)" in
    MINGW*|MSYS*)
        # The fork's Windows bootstrap links native helpers absent from older vc
        # snapshots. --local preserves the pinned vc checkout above.
        export VFLAGS='-cc gcc -gc none'
        MSYS2_ARG_CONV_EXCL='*' cmd.exe /c makev.bat -gcc --local
        ./v.exe version
        ;;
    *)
        compiler_cc=${CC:-clang}
        # Bootstrap without a prebuilt TCC/libgc archive (which can target glibc
        # on an otherwise musl system). The final application still uses GC.
        sh cmd/tools/vc_compat.sh vc/v.c "$compiler_cc" \
            -DCUSTOM_DEFINE_v1_fallback -std=gnu11 -w -o v1 -- -lm -lpthread
        ./v1 -no-parallel -cc "$compiler_cc" -gc none -o v2 cmd/v
        ./v2 -no-parallel -cc "$compiler_cc" -gc none -o v cmd/v
        rm -f v1 v2
        ./v version
        ;;
esac
git rev-parse HEAD
