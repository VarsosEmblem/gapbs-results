#!/usr/bin/env bash
# Build GAPBS and install into $RESULTS_DIR/bin/<tag>/.
#
#   plain       clang-plain++        + jemalloc-og        (baseline)
#   plain-no-tcache is not a separate build. The compare scripts run the plain
#   binary with MALLOC_CONF=tcache:false.
#   plainje     clang-plain++        + jemalloc           (chonk no analysis)
#   chonk       clang-chonky++       + jemalloc           (chonk)
#   chonk-early clang-chonky-early++ + jemalloc           (modified analysis)
#   chonk-scoped CHONK_SCOPEDXX      + jemalloc           (cset_assign only in timed kernels)
#   happy       happy clang++        + system malloc      (different analysis, -lautohbw)
#   happy-mod   HAPPY_MODXX          + system malloc      (same link as happy; placeholder compiler)
#   happy-src   clang-plain++ on $HAPPY_SRC_DIR (~/gapbs-happy, manual happyPriority calls)
#                                                        + system malloc, -lautohbw
#   bcda        bcda clang++         + system malloc      (placeholder compiler, -lautohbw)
#   autohbw     clang-plain++        + system malloc
#   ddr-only    clang-plain++        + system malloc      (same link as autohbw)
#   hbm-only    clang-plain++        + system malloc      (same link as ddr-only)
#   glibc       clang-plain++        + system malloc      (glibc malloc, no preload)
#   mimalloc    clang-plain++        + mimalloc           (~/mimalloc/out/release)
#
# happy, happy-mod, happy-src, bcda, autohbw, ddr-only, hbm-only, glibc, and mimalloc do not link jemalloc.
# mimalloc links libmimalloc.so from $MIMALLOC_LIBDIR (default ~/mimalloc/out/release).
# compare_gapbs.sh LD_PRELOADs libautohbw.so for happy, happy-mod, happy-src, bcda, autohbw,
# ddr-only, and hbm-only. glibc is the default system allocator.
# happy-src builds $HAPPY_SRC_DIR (default ~/gapbs-happy) instead of $GAPBS_DIR. happyPriority
# comes from the custom libautohbw at $HAPPY_AUTOHBW_SO.
# modmalloc is a compare-only tag: same binaries as glibc, LD_PRELOAD
# $MODMALLOC_PRELOAD (default ~/modular-malloc/bin/libmodmalloc.so). Build glibc first.
# bcda preloads the same library as happy. Set BCDAXX to the bcda clang++.
# ddr-only sets AUTO_HBW_SIZE=150G so allocations stay on DDR.
# hbm-only sets AUTO_HBW_SIZE=2 so allocations larger than 2 bytes go to HBM.
#
# Usage:
#   ./build_gapbs.sh
#   TAGS="plain" ./build_gapbs.sh                    # one config
#   CHONK_EARLYXX=/path/to/clang++ ./build_gapbs.sh # set placeholder path
#   CHONK_SCOPEDXX=/path/to/clang++ ./build_gapbs.sh # chonk clang++ with -coaccess-roots
#   HAPPYXX=/path/to/clang++ ./build_gapbs.sh
#   HAPPY_MODXX=/path/to/clang++ ./build_gapbs.sh
#   HAPPY_SRC_DIR=/path/to/gapbs-happy TAGS=happy-src ./build_gapbs.sh
#   BCDAXX=/path/to/clang++ ./build_gapbs.sh
#   GENERATE_GRAPHS=1 ./build_gapbs.sh               # also write default .sg/.wsg files
#   MACHINE=h0 TAGS=glibc ./build_gapbs.sh           # per-machine compiler/lib paths
set -euo pipefail

GAPBS_DIR="${GAPBS_DIR:-$HOME/gapbs}"
HAPPY_SRC_DIR="${HAPPY_SRC_DIR:-$HOME/gapbs-happy}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/gapbs-results}"
MACHINE="${MACHINE:-h0}"
# shellcheck source=machine_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/machine_env.sh"
# OPENMP (runtime name) and OMP_LIBDIR (runtime location, empty if on the default path) come
# from machine_env.sh. Explicit environment variables still win.
OPENMP="${OPENMP:-libgomp}"
OMP_LIBDIR="${OMP_LIBDIR:-}"
TAGS="${TAGS:-plain plainje chonk chonk-early chonk-scoped happy happy-mod happy-src bcda autohbw ddr-only hbm-only glibc mimalloc}"
JOBS="${JOBS:-$(nproc)}"
SUITE="${SUITE:-bc bfs cc cc_sv pr pr_spmv sssp tc converter}"
GRAPHS="${GRAPHS:-kron22 urand22}"
GENERATE_GRAPHS="${GENERATE_GRAPHS:-0}"

PLAINXX="${PLAINXX:-$LLVM_DIR/bin/clang-plain++}"
CHONKXX="${CHONKXX:-$LLVM_DIR/bin/clang-chonky++}"
CHONK_EARLYXX="${CHONK_EARLYXX:-$LLVM_DIR/bin/clang-chonky-early++}"
# Placeholder until the scoped compiler is installed on the build machine.
CHONK_SCOPEDXX="${CHONK_SCOPEDXX:-$LLVM_DIR/bin/clang-chonky-scoped++}"
HAPPYXX="${HAPPYXX:-$LLVM_DIR/bin/clang-happy++}"
# Placeholder until the modified happy compiler is installed on the build machine.
HAPPY_MODXX="${HAPPY_MODXX:-$LLVM_DIR/bin/clang-happy-mod++}"
BCDAXX="${BCDAXX:-$LLVM_DIR/bin/clang-bcda++}"
HAPPY_AUTOHBW_LIBDIR="$(dirname "$HAPPY_AUTOHBW_SO")"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$GAPBS_DIR/src" ]] || die "GAPBS sources not found in $GAPBS_DIR"
[[ -x "$PLAINXX" ]] || die "missing $PLAINXX"
[[ -x "$CHONKXX" ]] || die "missing $CHONKXX"
[[ -x "$CHONK_EARLYXX" ]] || die "missing $CHONK_EARLYXX (set CHONK_EARLYXX to your chonk-early clang++)"
[[ -e "$JEMALLOC_OG/lib/libjemalloc.so" ]] || die "missing $JEMALLOC_OG/lib/libjemalloc.so"
[[ -e "$JEMALLOC/lib/libjemalloc.so" ]] || die "missing $JEMALLOC/lib/libjemalloc.so"
if [[ " $TAGS " == *" chonk-scoped "* ]]; then
  [[ -x "$CHONK_SCOPEDXX" ]] || die "missing $CHONK_SCOPEDXX (set CHONK_SCOPEDXX to the chonk clang++ with -coaccess-roots)"
fi
if [[ " $TAGS " == *" happy "* ]]; then
  [[ -x "$HAPPYXX" ]] || die "missing $HAPPYXX (set HAPPYXX to the happy clang++)"
  [[ -e "$HAPPY_AUTOHBW_SO" ]] || die "missing $HAPPY_AUTOHBW_SO"
fi
if [[ " $TAGS " == *" happy-mod "* ]]; then
  [[ -x "$HAPPY_MODXX" ]] || die "missing $HAPPY_MODXX (set HAPPY_MODXX to the happy-mod clang++)"
  [[ -e "$HAPPY_AUTOHBW_SO" ]] || die "missing $HAPPY_AUTOHBW_SO"
fi
if [[ " $TAGS " == *" bcda "* ]]; then
  [[ -x "$BCDAXX" ]] || die "missing $BCDAXX (set BCDAXX to the bcda clang++)"
  [[ -e "$HAPPY_AUTOHBW_SO" ]] || die "missing $HAPPY_AUTOHBW_SO"
fi
if [[ " $TAGS " == *" happy-src "* ]]; then
  [[ -d "$HAPPY_SRC_DIR/src" ]] || die "GAPBS happy sources not found in $HAPPY_SRC_DIR (set HAPPY_SRC_DIR)"
  [[ -e "$HAPPY_AUTOHBW_SO" ]] || die "missing $HAPPY_AUTOHBW_SO (must be the custom libautohbw with happyPriority)"
fi
if [[ " $TAGS " == *" mimalloc "* ]]; then
  [[ -e "$MIMALLOC_LIBDIR/libmimalloc.so" ]] || die "missing $MIMALLOC_LIBDIR/libmimalloc.so"
fi

mkdir -p "$RESULTS_DIR/wrappers" "$RESULTS_DIR/bin"

# write_wrapper OUT CLANG ALLOC_PREFIX LINK_LIBS [extra compiler flags...]
# An empty ALLOC_PREFIX skips -ljemalloc and its -L/-rpath (system malloc).
write_wrapper() {
  local out="$1" clang="$2" alloc="$3" link_libs="$4"
  shift 4
  local -a lines=()
  lines+=("exec \"$clang\" --gcc-install-dir=\"$GCC_INSTALL_DIR\" $* \"\$@\"")
  if [[ -n "$STDCXX_LIB" ]]; then
    lines+=("  -L\"$STDCXX_LIB\" -Wl,-rpath,\"$STDCXX_LIB\"")
  fi
  if [[ -n "$alloc" ]]; then
    lines+=("  -L\"$alloc/lib\" $link_libs -Wl,-rpath,\"$alloc/lib\"")
  elif [[ -n "$link_libs" ]]; then
    lines+=("  $link_libs")
  fi
  {
    echo "#!/bin/sh"
    local i
    for i in "${!lines[@]}"; do
      if (( i < ${#lines[@]} - 1 )); then
        echo "${lines[$i]} \\"
      else
        echo "${lines[$i]}"
      fi
    done
  } >"$out"
  chmod +x "$out"
}

write_wrapper "$RESULTS_DIR/wrappers/plain++"    "$PLAINXX" "$JEMALLOC_OG" "-ljemalloc"
write_wrapper "$RESULTS_DIR/wrappers/plainje++"  "$PLAINXX" "$JEMALLOC" "-ljemalloc"
write_wrapper "$RESULTS_DIR/wrappers/chonk++"    "$CHONKXX" "$JEMALLOC" "-ljemalloc" \
  -mllvm -coaccess-stats
write_wrapper "$RESULTS_DIR/wrappers/chonk-early++" "$CHONK_EARLYXX" "$JEMALLOC" "-ljemalloc" \
  -mllvm -coaccess-stats
# One wrapper compiles every benchmark. The whole module is analyzed.
# Each root names that benchmark's kernel. Sets are built only from pairs
# recorded inside the matching kernel, so a kernel with no real co-access
# gets no cset_assign.
write_wrapper "$RESULTS_DIR/wrappers/chonk-scoped++" "$CHONK_SCOPEDXX" "$JEMALLOC" "-ljemalloc" \
  -mllvm -coaccess-stats \
  -mllvm -coaccess-roots=DOBFS,DeltaStep,Brandes,PageRankPullGS,PageRankPull,Afforest,ShiloachVishkin,Hybrid
write_wrapper "$RESULTS_DIR/wrappers/happy++" "$HAPPYXX" "" \
  "-L$HAPPY_AUTOHBW_LIBDIR -lautohbw -Wl,-rpath,$HAPPY_AUTOHBW_LIBDIR"
write_wrapper "$RESULTS_DIR/wrappers/happy-mod++" "$HAPPY_MODXX" "" \
  "-L$HAPPY_AUTOHBW_LIBDIR -lautohbw -Wl,-rpath,$HAPPY_AUTOHBW_LIBDIR"
write_wrapper "$RESULTS_DIR/wrappers/happy-src++" "$PLAINXX" "" \
  "-L$HAPPY_AUTOHBW_LIBDIR -lautohbw -Wl,-rpath,$HAPPY_AUTOHBW_LIBDIR"
write_wrapper "$RESULTS_DIR/wrappers/bcda++" "$BCDAXX" "" \
  "-L$HAPPY_AUTOHBW_LIBDIR -lautohbw -Wl,-rpath,$HAPPY_AUTOHBW_LIBDIR"
write_wrapper "$RESULTS_DIR/wrappers/autohbw++" "$PLAINXX" "" ""
write_wrapper "$RESULTS_DIR/wrappers/ddr-only++" "$PLAINXX" "" ""
write_wrapper "$RESULTS_DIR/wrappers/hbm-only++" "$PLAINXX" "" ""
write_wrapper "$RESULTS_DIR/wrappers/glibc++" "$PLAINXX" "" ""
write_wrapper "$RESULTS_DIR/wrappers/mimalloc++" "$PLAINXX" "" \
  "-L$MIMALLOC_LIBDIR -lmimalloc -Wl,-rpath,$MIMALLOC_LIBDIR"

# Passing CXX_FLAGS on the command line suppresses the Makefile's own -fopenmp, so the
# OpenMP flag is added here. chonk* tags always keep their libgomp build.
flags_for_tag() {
  local tag="$1" omp="$OPENMP" libdir="$OMP_LIBDIR"
  if [[ "$tag" == chonk* && "$OPENMP" != 0 ]]; then
    omp=libgomp
    libdir=""
  fi
  if [[ "$OPENMP" == 0 ]]; then
    echo "-std=c++11 -O3 -Wall"
  elif [[ -n "$libdir" ]]; then
    echo "-std=c++11 -O3 -Wall -fopenmp=${omp} -L${libdir} -Wl,-rpath,${libdir}"
  else
    echo "-std=c++11 -O3 -Wall -fopenmp=${omp}"
  fi
}
if [[ "$OPENMP" == 0 ]]; then
  export SERIAL=1
else
  export SERIAL=0
fi

build_one() {
  local tag="$1" wrapper="$RESULTS_DIR/wrappers/${tag}++"
  [[ -x "$wrapper" ]] || die "no wrapper for tag '$tag'"
  local dest="$RESULTS_DIR/bin/$tag"
  # happy-src builds the manually instrumented tree; every other tag builds $GAPBS_DIR.
  local src="$GAPBS_DIR"
  if [[ "$tag" == happy-src ]]; then
    src="$HAPPY_SRC_DIR"
  fi
  echo "==== build $tag -> $dest (source $src) ===="
  echo "CXX=$wrapper"
  local cxx_flags
  cxx_flags="$(flags_for_tag "$tag")"
  echo "CXX_FLAGS=$cxx_flags"
  make -C "$src" clean
  make -C "$src" -j"$JOBS" CXX="$wrapper" CXX_FLAGS="$cxx_flags" $SUITE
  mkdir -p "$dest"
  local bin
  for bin in $SUITE; do
    [[ -x "$src/$bin" ]] || die "build $tag did not produce $bin"
    cp -f "$src/$bin" "$dest/$bin"
  done
  # The libomp build must produce real OpenMP parallel code and load libomp.so. A missing or
  # ignored runtime fails here instead of silently running single-threaded.
  if [[ "$cxx_flags" == *"-fopenmp=libomp"* ]]; then
    for bin in $SUITE; do
      [[ "$bin" == converter ]] && continue
      [[ -n "$(nm -D "$dest/$bin" | grep __kmpc_fork_call)" ]] \
        || die "$tag/$bin has no OpenMP parallel calls; the OpenMP runtime was not used"
      [[ -n "$(ldd "$dest/$bin" | grep libomp.so)" ]] \
        || die "$tag/$bin does not load libomp.so"
    done
  fi
  echo "installed $tag: $(ls "$dest")"
}

for tag in $TAGS; do
  build_one "$tag"
done

make -C "$GAPBS_DIR" clean
if [[ " $TAGS " == *" happy-src "* ]]; then
  make -C "$HAPPY_SRC_DIR" clean
fi

parse_graph() {
  local g="$1"
  if [[ "$g" =~ ^(kron|urand)([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  else
    die "unknown graph '$g' (expected kronN or urandN)"
  fi
}

generate_graphs() {
  local conv="" tag
  for tag in $TAGS; do
    if [[ -x "$RESULTS_DIR/bin/$tag/converter" ]]; then
      conv="$RESULTS_DIR/bin/$tag/converter"
      break
    fi
  done
  [[ -n "$conv" ]] || die "no converter installed under $RESULTS_DIR/bin"
  local gdir="$RESULTS_DIR/graphs"
  mkdir -p "$gdir"
  local g kind scale
  for g in $GRAPHS; do
    read -r kind scale <<<"$(parse_graph "$g")"
    local gen
    if [[ "$kind" == kron ]]; then
      gen=(-g "$scale" -k 16)
    else
      gen=(-u "$scale" -k 16)
    fi
    if [[ ! -f "$gdir/$g.sg" ]]; then
      echo "==== generate $g.sg ===="
      "$conv" "${gen[@]}" -b "$gdir/$g.sg"
    else
      echo "skip $g.sg (exists)"
    fi
    if [[ ! -f "$gdir/$g.wsg" ]]; then
      echo "==== generate $g.wsg ===="
      "$conv" "${gen[@]}" -w -b "$gdir/$g.wsg"
    else
      echo "skip $g.wsg (exists)"
    fi
    ln -sfn "$g.sg" "$gdir/${g}U.sg"
  done
}

if [[ "$GENERATE_GRAPHS" == 1 ]]; then
  generate_graphs
fi

echo
echo "binaries -> $RESULTS_DIR/bin/{$(echo $TAGS | tr ' ' ',')}/"
if [[ "$GENERATE_GRAPHS" == 1 ]]; then
  echo "graphs   -> $RESULTS_DIR/graphs/"
fi
