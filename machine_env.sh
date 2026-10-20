# Per-machine default paths for build_gapbs.sh and compare_gapbs*.sh.
# Source after MACHINE is set. Explicit env vars always win (: "${VAR:=...}").
#
#   MACHINE=h0    ./build_gapbs.sh
#   MACHINE=cn902 ./build_gapbs.sh
#
# Known machines: h0, cn902

MACHINE="${MACHINE:-h0}"

case "$MACHINE" in
  h0)
    : "${LLVM_DIR:=$HOME/llvm-19-build}"
    : "${GCC_INSTALL_DIR:=/usr/lib/gcc/x86_64-linux-gnu/13}"
    : "${STDCXX_LIB:=}"
    : "${JEMALLOC_OG:=$HOME/jemalloc-og}"
    : "${JEMALLOC:=$HOME/jemalloc}"
    : "${HAPPY_AUTOHBW_SO:=$HOME/memkind/autohbw/.libs/libautohbw.so}"
    : "${HAPPY_PRELOAD:=$HOME/memkind/autohbw/.libs/libautohbw.so}"
    : "${BCDA_PRELOAD:=$HAPPY_PRELOAD}"
    : "${AUTOHBW_PRELOAD:=$HOME/memkind-og/autohbw/.libs/libautohbw.so}"
    : "${DDR_ONLY_PRELOAD:=$AUTOHBW_PRELOAD}"
    : "${HBM_ONLY_PRELOAD:=$AUTOHBW_PRELOAD}"
    : "${MODMALLOC_PRELOAD:=$HOME/modular-malloc/bin/libmodmalloc.so}"
    : "${MIMALLOC:=$HOME/mimalloc}"
    : "${MIMALLOC_LIBDIR:=$MIMALLOC/out/release}"
    : "${OPENMP:=libomp}"
    : "${OMP_LIBDIR:=$HOME/llvm-19-build/runtimes/runtimes-bins/openmp/runtime/src}"
    ;;
  cn902)
    : "${LLVM_DIR:=$HOME/llvm-build}"
    : "${GCC_INSTALL_DIR:=/vast/projects/opt/rhel8/x86_64/gcc/13.1.0/bin/../lib/gcc/x86_64-pc-linux-gnu/13.1.0/}"
    : "${STDCXX_LIB:=/vast/projects/opt/rhel8/x86_64/gcc/13.1.0/lib64}"
    : "${JEMALLOC_OG:=$HOME/jemalloc-5.3.0}"
    : "${JEMALLOC:=$HOME/jemalloc}"
    : "${HAPPY_AUTOHBW_SO:=/vast/home/vchoung/memkind/autohbw/.libs/libautohbw.so}"
    : "${HAPPY_PRELOAD:=/vast/home/vchoung/memkind/autohbw/.libs/libautohbw.so}"
    : "${BCDA_PRELOAD:=$HAPPY_PRELOAD}"
    : "${AUTOHBW_PRELOAD:=/vast/home/vchoung/memkind-og/autohbw/.libs/libautohbw.so}"
    : "${DDR_ONLY_PRELOAD:=$AUTOHBW_PRELOAD}"
    : "${HBM_ONLY_PRELOAD:=$AUTOHBW_PRELOAD}"
    : "${MODMALLOC_PRELOAD:=$HOME/modular-malloc/bin/libmodmalloc.so}"
    : "${MIMALLOC:=$HOME/mimalloc}"
    : "${MIMALLOC_LIBDIR:=$MIMALLOC/out/release}"
    : "${OPENMP:=libomp}"
    : "${OMP_LIBDIR:=}"
    ;;
  *)
    echo "error: unknown MACHINE='$MACHINE' (expected h0 or cn902)" >&2
    echo "  override paths explicitly, or add a case to machine_env.sh" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
