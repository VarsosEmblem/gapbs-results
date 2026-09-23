#!/usr/bin/env bash
# Build GAPBS and install into $RESULTS_DIR/bin/<tag>/.
#
#   plain       clang-plain++        + jemalloc-og        (baseline)
#   plainje     clang-plain++        + jemalloc           (chonk no analysis)
#   chonk       clang-chonky++       + jemalloc           (chonk)
#   chonk-early clang-chonky-early++ + jemalloc           (modified analysis)
#   happy       happy clang++        + happy allocator    (different analysis, -lmemkind)
#   autohbw     clang-plain++        + autohbw allocator  (-lmemkind)
#
# Usage:
#   ./build_gapbs.sh
#   TAGS="plain" ./build_gapbs.sh                    # one config
#   CHONK_EARLYXX=/path/to/clang++ ./build_gapbs.sh # set placeholder path
#   HAPPYXX=/path/to/clang++ HAPPY_ALLOC=/path/to/alloc ./build_gapbs.sh
#   AUTOHBW_ALLOC=/path/to/alloc ./build_gapbs.sh
#   GENERATE_GRAPHS=1 ./build_gapbs.sh               # also write default .sg/.wsg files
set -euo pipefail

GAPBS_DIR="${GAPBS_DIR:-$HOME/gapbs}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/gapbs-results}"
LLVM_DIR="${LLVM_DIR:-$HOME/llvm-build}"
GCC_INSTALL_DIR="${GCC_INSTALL_DIR:-/vast/projects/opt/rhel8/x86_64/gcc/13.1.0/bin/../lib/gcc/x86_64-pc-linux-gnu/13.1.0/}"
STDCXX_LIB="/vast/projects/opt/rhel8/x86_64/gcc/13.1.0/lib64"
JEMALLOC_OG="${JEMALLOC_OG:-$HOME/jemalloc-5.3.0}"
JEMALLOC="${JEMALLOC:-$HOME/jemalloc}"
# Placeholder install prefixes. Override before building these tags.
HAPPY_ALLOC="${HAPPY_ALLOC:-/path/to/happy-allocator}"
AUTOHBW_ALLOC="${AUTOHBW_ALLOC:-/path/to/autohbw-allocator}"
# Clang 19 has no matching libomp in llvm-19-build; PARSEC uses libgomp.
OPENMP="${OPENMP:-libgomp}"
TAGS="${TAGS:-plain plainje chonk chonk-early happy autohbw}"
JOBS="${JOBS:-$(nproc)}"
SUITE="${SUITE:-bc bfs cc cc_sv pr pr_spmv sssp tc converter}"
GRAPHS="${GRAPHS:-kron22 urand22}"
GENERATE_GRAPHS="${GENERATE_GRAPHS:-0}"

PLAINXX="$LLVM_DIR/bin/clang-plain++"
CHONKXX="$LLVM_DIR/bin/clang-chonky++"
CHONK_EARLYXX="$LLVM_DIR/bin/clang-chonky-early++"
# Placeholder compiler for the happy analysis.
HAPPYXX="${HAPPYXX:-/path/to/happy/clang++}"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$GAPBS_DIR/src" ]] || die "GAPBS sources not found in $GAPBS_DIR"
[[ -x "$PLAINXX" ]] || die "missing $PLAINXX"
[[ -x "$CHONKXX" ]] || die "missing $CHONKXX"
[[ -x "$CHONK_EARLYXX" ]] || die "missing $CHONK_EARLYXX (set CHONK_EARLYXX to your chonk-early clang++)"
[[ -e "$JEMALLOC_OG/lib/libjemalloc.so" ]] || die "missing $JEMALLOC_OG/lib/libjemalloc.so"
[[ -e "$JEMALLOC/lib/libjemalloc.so" ]] || die "missing $JEMALLOC/lib/libjemalloc.so"
if [[ " $TAGS " == *" happy "* ]]; then
  [[ -x "$HAPPYXX" ]] || die "missing $HAPPYXX (set HAPPYXX to the happy clang++)"
  [[ -e "$HAPPY_ALLOC/lib/libjemalloc.so" ]] || die "missing $HAPPY_ALLOC/lib/libjemalloc.so (set HAPPY_ALLOC)"
fi
if [[ " $TAGS " == *" autohbw "* ]]; then
  [[ -e "$AUTOHBW_ALLOC/lib/libjemalloc.so" ]] || die "missing $AUTOHBW_ALLOC/lib/libjemalloc.so (set AUTOHBW_ALLOC)"
fi

mkdir -p "$RESULTS_DIR/wrappers" "$RESULTS_DIR/bin"

# write_wrapper OUT CLANG ALLOC_PREFIX LINK_LIBS [extra compiler flags...]
write_wrapper() {
  local out="$1" clang="$2" alloc="$3" link_libs="$4"
  shift 4
  {
    echo "#!/bin/sh"
    echo "exec \"$clang\" --gcc-install-dir=\"$GCC_INSTALL_DIR\" $* \"\$@\" \\"
    if [[ -n "$STDCXX_LIB" ]]; then
      echo "  -L\"$STDCXX_LIB\" -Wl,-rpath,\"$STDCXX_LIB\" \\"
    fi
    echo "  -L\"$alloc/lib\" $link_libs -Wl,-rpath,\"$alloc/lib\""
  } >"$out"
  chmod +x "$out"
}

write_wrapper "$RESULTS_DIR/wrappers/plain++"    "$PLAINXX" "$JEMALLOC_OG" "-ljemalloc"
write_wrapper "$RESULTS_DIR/wrappers/plainje++"  "$PLAINXX" "$JEMALLOC" "-ljemalloc"
write_wrapper "$RESULTS_DIR/wrappers/chonk++"    "$CHONKXX" "$JEMALLOC" "-ljemalloc" \
  -mllvm -coaccess-stats
write_wrapper "$RESULTS_DIR/wrappers/chonk-early++" "$CHONK_EARLYXX" "$JEMALLOC" "-ljemalloc" \
  -mllvm -coaccess-stats
write_wrapper "$RESULTS_DIR/wrappers/happy++"    "$HAPPYXX" "$HAPPY_ALLOC" "-ljemalloc -lmemkind"
write_wrapper "$RESULTS_DIR/wrappers/autohbw++"  "$PLAINXX" "$AUTOHBW_ALLOC" "-ljemalloc -lmemkind"

# Passing CXX_FLAGS on the command line suppresses the Makefile += of -fopenmp
# (libomp). Use libgomp instead, matching PARSEC's clang-*.bldconf for freqmine.
if [[ "$OPENMP" == 0 ]]; then
  CXX_FLAGS="-std=c++11 -O3 -Wall"
  export SERIAL=1
else
  CXX_FLAGS="-std=c++11 -O3 -Wall -fopenmp=${OPENMP}"
  export SERIAL=0
fi

build_one() {
  local tag="$1" wrapper="$RESULTS_DIR/wrappers/${tag}++"
  [[ -x "$wrapper" ]] || die "no wrapper for tag '$tag'"
  local dest="$RESULTS_DIR/bin/$tag"
  echo "==== build $tag -> $dest ===="
  echo "CXX=$wrapper"
  echo "CXX_FLAGS=$CXX_FLAGS"
  make -C "$GAPBS_DIR" clean
  make -C "$GAPBS_DIR" -j"$JOBS" CXX="$wrapper" CXX_FLAGS="$CXX_FLAGS" $SUITE
  mkdir -p "$dest"
  local bin
  for bin in $SUITE; do
    [[ -x "$GAPBS_DIR/$bin" ]] || die "build $tag did not produce $bin"
    cp -f "$GAPBS_DIR/$bin" "$dest/$bin"
  done
  echo "installed $tag: $(ls "$dest")"
}

for tag in $TAGS; do
  build_one "$tag"
done

make -C "$GAPBS_DIR" clean

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
