#!/bin/bash

set -e

source "$(cd "$(dirname "$0")" ; pwd)/env/cross-env.sh"

show_help()
{
    cat <<EOF

   Usage: $(basename $0) OPTION* <tool>

   Options:

      --cleanup              Remove temporary files after building
      --no-cleanup           Do not remove temporary files after building
      --force                Force reinstall of target

   Tool:

      gcc-x.y.z
      llvm-x.y.z

   Examples:

      # Install gcc version 13.1.0 to $TOOLCHAINS_DIR
      > $(basename $0) gcc-13.1.0

      # Install llvm version 16.0.2 to $TOOLCHAINS_DIR
      > $(basename $0) llvm-16.0.2

   Repos:

      https://github.com/gcc-mirror/gcc
      https://github.com/llvm/llvm-project

EOF
} 

# ------------------------------------------------------------------------- llvm

build_llvm()
{
    local CLANG_V="$1"
    local TAG="$2"
    local LLVM_DIR="llvm"

    local SRC_D="$TMPD/$LLVM_DIR"
    local BUILD_D="$TMPD/build-llvm-${TAG}"
    local INSTALL_PREFIX="${TOOLCHAINS_DIR}/llvm-${CLANG_V}"
    
    rm -rf "$BUILD_D"
    mkdir -p "$SRC_D"
    mkdir -p "$BUILD_D"

    cd "$SRC_D"

    if [ ! -d "llvm-project" ] ; then
        git clone https://github.com/llvm/llvm-project.git
    fi
    cd llvm-project
    git checkout main
    git pull origin main
    git checkout "llvmorg-${CLANG_V}"

    cd "$BUILD_D"

    # NOTE, to build lldb, may need to specify the python3
    #       variables below, and something else for CURSES
    # -D PYTHON_EXECUTABLE=/usr/bin/python3.6m \
    # -D PYTHON_LIBRARY=/usr/lib/python3.6/config-3.6m-x86_64-linux-gnu/libpython3.6m.so \
    # -D PYTHON_INCLUDE_DIR=/usr/include/python3.6m \
    # -D CURSES_LIBRARY=/usr/lib/x86_64-linux-gnu/libncurses.so \
    # -D CURSES_INCLUDE_PATH=/usr/include/ \
    
    nice $CMAKE -G "Unix Makefiles" \
         -D LLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld" \
         -D LLVM_ENABLE_RUNTIMES="compiler-rt;libc;libcxx;libcxxabi;libunwind" \
         -D CMAKE_BUILD_TYPE=Release \
         -D CMAKE_C_COMPILER=$HOST_CC \
         -D CMAKE_CXX_COMPILER=$HOST_CXX \
         -D LLVM_ENABLE_ASSERTIONS=Off \
         -D LIBCXX_ENABLE_STATIC_ABI_LIBRARY=Yes \
         -D LIBCXX_ENABLE_SHARED=YES \
         -D LIBCXX_ENABLE_STATIC=YES \
         -D LLVM_BUILD_LLVM_DYLIB=YES \
         -D COMPILER_RT_ENABLE_IOS:BOOL=Off \
         -D CMAKE_INSTALL_PREFIX:PATH="$INSTALL_PREFIX" \
         $SRC_D/llvm-project/llvm

    nice make -j$(nproc) 2>$BUILD_D/stderr.text | tee $BUILD_D/stdout.text
    nice make install 2>>$BUILD_D/stderr.text | tee -a $BUILD_D/stdout.text
    cat $BUILD_D/stderr.text   
}

# -------------------------------------------------------------------------- gcc

build_gcc()
{
    local TAG="$1"
    local SUFFIX="$1"
    if [ "$2" != "" ] ; then SUFFIX="$2" ; fi
    
    local MAJOR_VERSION="$(echo "$SUFFIX" | sed 's,\..*$,,')"
    local SRCD="$TMPD/$SUFFIX"
    
    mkdir -p "$SRCD"
    cd "$SRCD"
    if [ ! -d "gcc" ] ;then
        git clone https://github.com/gcc-mirror/gcc.git
    fi
    
    cd gcc
    git fetch
    git checkout releases/gcc-${TAG}
    contrib/download_prerequisites

    if [ -d "$SRCD/build" ] ; then rm -rf "$SRCD/build" ; fi
    mkdir -p "$SRCD/build"
    cd "$SRCD/build"

    local PREFIX="${TOOLCHAINS_DIR}/gcc-${SUFFIX}"

    export CC=$HOST_CC
    export CXX=$HOST_CXX
    nice ../gcc/configure --prefix=${PREFIX} \
         --enable-languages=c,c++,objc,obj-c++ \
         --disable-multilib \
         --program-suffix=-${MAJOR_VERSION} \
         --enable-checking=release \
         --with-gcc-major-version-only
    nice make -j$(nproc) 2>$SRCD/build/stderr.text | tee $SRCD/build/stdout.text
    nice make install | tee -a $SRCD/build/stdout.text
}

# ------------------------------------------------------------------------ parse

(( $# == 0 )) && show_help && exit 0 || true
for ARG in "$@" ; do
    [ "$ARG" = "-h" ] || [ "$ARG" = "--help" ] && show_help && exit 0
done

CLEANUP="True"
FORCE_INSTALL="False"

while (( $# > 0 )) ; do
    ARG="$1"
    shift
    [ "$ARG" = "--cleanup" ]       && export CLEANUP="True" && continue
    [ "$ARG" = "--no-cleanup" ]    && export CLEANUP="False" && continue
    [ "$ARG" = "--force" ] || [ "$ARG" = "-f" ] && export FORCE_INSTALL="True" && continue

    if [ "${ARG:0:3}" = "gcc" ] ; then
        COMMAND="build_gcc ${ARG:4}"
        CC_MAJOR_VERSION="$(echo ${ARG:4} | awk -F. '{ print $1 }')"
        EXEC="$TOOLCHAINS_DIR/$ARG/bin/gcc-$CC_MAJOR_VERSION"
        continue
    fi    

    if [ "${ARG:0:4}" = "llvm" ] || [ "${ARG:0:5}" = "clang" ] ; then
        [ "${ARG:0:4}" = "llvm" ]  && VERSION="${ARG:5}" || true
        [ "${ARG:0:5}" = "clang" ] && VERSION="${ARG:6}" || true
        COMMAND="build_llvm $VERSION"
        EXEC="$TOOLCHAINS_DIR/llvm-$VERSION/bin/clang"
        continue
    fi  

    echo "unexpected argument: '$ARG'" 1>&2 && exit 1
done

if [ "$COMMAND" = "" ] ; then
    echo "Must specify a build command!" 1>&2 && exit 1
fi

if [ "$CLEANUP" = "True" ] ; then
    TMPD="$(mktemp -d /tmp/$(basename "$SCRIPT_NAME" .sh).XXXXXX)"
else
    TMPD="/tmp/$(basename "$SCRIPT_NAME" .sh)-${USER}"
fi

trap cleanup EXIT
cleanup()
{
    if [ "$CLEANUP" = "True" ] ; then
        rm -rf "$TMPD"
    fi
}

# ----------------------------------------------------------------------- action

if [ "$FORCE_INSTALL" = "True" ] || [ ! -x "$EXEC" ] ; then
    ensure_directory "$TOOLCHAINS_DIR"
    install_dependences
    $COMMAND
else
    echo "Skipping installation, executable found: '$EXEC'"
fi

