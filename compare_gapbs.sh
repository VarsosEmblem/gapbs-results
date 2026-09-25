#!/usr/bin/env bash
# Interleaved GAPBS comparison across the CHONK configs.
#
#   clang-plain       + jemalloc-og        (baseline)
#   clang-plain-no-tcache + jemalloc-og    (same binary as plain; MALLOC_CONF=tcache:false)
#   clang-plainje     + jemalloc           (chonk no analysis)
#   clang-chonk       + jemalloc           (chonk)
#   clang-chonk-early + jemalloc           (modified analysis)
#   clang-happy       + system malloc      (different analysis; LD_PRELOAD libautohbw)
#   clang-happy-mod   + system malloc      (same runtime as happy; built with HAPPY_MODXX)
#   clang-bcda        + system malloc      (placeholder compiler, -lautohbw; LD_PRELOAD happy's libautohbw)
#   clang-autohbw     + system malloc      (clang-plain; LD_PRELOAD libautohbw)
#   clang-ddr-only    + system malloc      (clang-plain; LD_PRELOAD libautohbw, AUTO_HBW_SIZE=150G)
#   clang-hbm-only    + system malloc      (clang-plain; LD_PRELOAD libautohbw, AUTO_HBW_SIZE=2)
#   clang-glibc       + system malloc      (clang-plain; glibc malloc, no LD_PRELOAD)
#
# Times come from GAPBS "Average Time" (kernel only), not wall-clock load.
# Graphs are shared serialized .sg/.wsg files under $RESULTS_DIR/graphs/.
#
# Usage:
#   ./compare_gapbs.sh
#   GRAPHS="kron22" NTHREADS=16 RUNS=5 ./compare_gapbs.sh
#   GRAPHS="kron10" KERNELS="bfs pr" RUNS=1 WARMUP=0 ./compare_gapbs.sh
#   START=6 RUNS=10 WARMUP=0 ./compare_gapbs.sh   # request at least r6; script auto-skips old runs
set -euo pipefail

GAPBS_DIR="${GAPBS_DIR:-$HOME/gapbs}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/gapbs-results}"
MACHINE="${MACHINE:-h0}"
GRAPHS="${GRAPHS:-kron22 urand22}"
KERNELS="${KERNELS:-bfs cc pr bc sssp tc}"
NTHREADS="${NTHREADS:-16}"
WARMUP="${WARMUP:-1}"
RUNS="${RUNS:-5}"
START="${START:-1}"
CONFIGS="${CONFIGS:-clang-plain clang-plain-no-tcache clang-plainje clang-chonk clang-chonk-early clang-happy clang-happy-mod clang-bcda clang-autohbw clang-ddr-only clang-hbm-only clang-glibc}"
TAGS="${TAGS:-plain plain-no-tcache plainje chonk chonk-early happy happy-mod bcda autohbw ddr-only hbm-only glibc}"
GRAPH_DIR="${GRAPH_DIR:-$RESULTS_DIR/graphs}"
HAPPY_PRELOAD="${HAPPY_PRELOAD:-/vast/home/vchoung/memkind/autohbw/.libs/libautohbw.so}"
BCDA_PRELOAD="${BCDA_PRELOAD:-$HAPPY_PRELOAD}"
AUTOHBW_PRELOAD="${AUTOHBW_PRELOAD:-/vast/home/vchoung/memkind-og/autohbw/.libs/libautohbw.so}"
DDR_ONLY_PRELOAD="${DDR_ONLY_PRELOAD:-/vast/home/vchoung/memkind-og/autohbw/.libs/libautohbw.so}"
HBM_ONLY_PRELOAD="${HBM_ONLY_PRELOAD:-/vast/home/vchoung/memkind-og/autohbw/.libs/libautohbw.so}"
# Larger than any single GAPBS allocation, so autohbw leaves every malloc on DDR.
DDR_ONLY_HBW_SIZE="${DDR_ONLY_HBW_SIZE:-150G}"
# Smaller than any real GAPBS allocation, so those mallocs go to HBM.
HBM_ONLY_HBW_SIZE="${HBM_ONLY_HBW_SIZE:-2}"

mkdir -p "$RESULTS_DIR"
read -r -a CONFIG_ARR <<<"$CONFIGS"
read -r -a TAG_ARR <<<"$TAGS"
if [[ ${#CONFIG_ARR[@]} -ne ${#TAG_ARR[@]} ]]; then
  echo "CONFIGS and TAGS must have the same number of entries" >&2
  exit 1
fi

die() { echo "error: $*" >&2; exit 1; }

if [[ " $TAGS " == *" happy "* || " $TAGS " == *" happy-mod "* ]]; then
  [[ -e "$HAPPY_PRELOAD" ]] || die "missing $HAPPY_PRELOAD"
fi
if [[ " $TAGS " == *" bcda "* ]]; then
  [[ -e "$BCDA_PRELOAD" ]] || die "missing $BCDA_PRELOAD"
fi
if [[ " $TAGS " == *" autohbw "* ]]; then
  [[ -e "$AUTOHBW_PRELOAD" ]] || die "missing $AUTOHBW_PRELOAD"
fi
if [[ " $TAGS " == *" ddr-only "* ]]; then
  [[ -e "$DDR_ONLY_PRELOAD" ]] || die "missing $DDR_ONLY_PRELOAD"
fi
if [[ " $TAGS " == *" hbm-only "* ]]; then
  [[ -e "$HBM_ONLY_PRELOAD" ]] || die "missing $HBM_ONLY_PRELOAD"
fi

parse_graph() {
  local g="$1"
  if [[ "$g" =~ ^(kron|urand)([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  else
    die "unknown graph '$g' (expected kronN or urandN)"
  fi
}

ensure_graphs() {
  local conv="" tag
  for tag in "${TAG_ARR[@]}"; do
    if [[ -x "$RESULTS_DIR/bin/$tag/converter" ]]; then
      conv="$RESULTS_DIR/bin/$tag/converter"
      break
    fi
  done
  [[ -n "$conv" ]] || die "no converter in $RESULTS_DIR/bin/<tag>/; run ./build_gapbs.sh first"
  mkdir -p "$GRAPH_DIR"
  local g kind scale
  for g in $GRAPHS; do
    read -r kind scale <<<"$(parse_graph "$g")"
    local gen
    if [[ "$kind" == kron ]]; then
      gen=(-g "$scale" -k 16)
    else
      gen=(-u "$scale" -k 16)
    fi
    if [[ ! -f "$GRAPH_DIR/$g.sg" ]]; then
      echo "==== generate $g.sg ===="
      "$conv" "${gen[@]}" -b "$GRAPH_DIR/$g.sg"
    fi
    if [[ ! -f "$GRAPH_DIR/$g.wsg" ]]; then
      echo "==== generate $g.wsg ===="
      "$conv" "${gen[@]}" -w -b "$GRAPH_DIR/$g.wsg"
    fi
    ln -sfn "$g.sg" "$GRAPH_DIR/${g}U.sg"
  done
}

kernel_args() {
  local kernel="$1" graph="$2"
  case "$kernel" in
    bfs)  echo -f "$GRAPH_DIR/$graph.sg" -n64 ;;
    cc|cc_sv) echo -f "$GRAPH_DIR/$graph.sg" -n16 ;;
    pr|pr_spmv) echo -f "$GRAPH_DIR/$graph.sg" -i1000 -t1e-4 -n16 ;;
    bc)   echo -f "$GRAPH_DIR/$graph.sg" -i4 -n16 ;;
    sssp) echo -f "$GRAPH_DIR/$graph.wsg" -n64 -d2 ;;
    tc)   echo -f "$GRAPH_DIR/${graph}U.sg" -n3 ;;
    *)    die "no args for kernel '$kernel'" ;;
  esac
}

parse_average() {
  awk '/^Average Time:/ { t=$NF } END { if (t != "") print t }' "$1"
}

crash_note() {
  if grep -Eiq 'Segmentation fault|Aborted|core dumped|bus error|Illegal instruction' "$1"; then
    echo crash
  elif ! grep -q '^Average Time:' "$1"; then
    echo no_time
  else
    echo ok
  fi
}

run_one() {
  local config="$1" kernel="$2" graph="$3" tag="$4" log="$5" run="$6"
  # plain-no-tcache is the plain binary with jemalloc tcache disabled.
  local bin_tag="$tag"
  [[ "$tag" == "plain-no-tcache" ]] && bin_tag="plain"
  local bin="$RESULTS_DIR/bin/$bin_tag/$kernel"
  [[ -x "$bin" ]] || die "missing $bin; run ./build_gapbs.sh"
  local -a args
  read -r -a args <<<"$(kernel_args "$kernel" "$graph")"
  export OMP_NUM_THREADS="$NTHREADS"
  # Keep GAPBS stdout/stderr and bash `time -p` (real/user/sys) in the log.
  # Clear autohbw vars first so they cannot leak in from the parent environment.
  local -a run_env=(env -u LD_PRELOAD -u AUTO_HBW_LOG -u AUTO_HBW_SIZE)
  case "$tag" in
    happy|happy-mod|bcda|autohbw|ddr-only|hbm-only)
      run_env+=(AUTO_HBW_LOG=-1)
      ;;
  esac
  case "$tag" in
    happy|happy-mod) run_env+=(LD_PRELOAD="$HAPPY_PRELOAD") ;;
    bcda) run_env+=(LD_PRELOAD="$BCDA_PRELOAD") ;;
    autohbw) run_env+=(LD_PRELOAD="$AUTOHBW_PRELOAD") ;;
    ddr-only)
      run_env+=(LD_PRELOAD="$DDR_ONLY_PRELOAD" AUTO_HBW_SIZE="$DDR_ONLY_HBW_SIZE")
      ;;
    hbm-only)
      run_env+=(LD_PRELOAD="$HBM_ONLY_PRELOAD" AUTO_HBW_SIZE="$HBM_ONLY_HBW_SIZE")
      ;;
    plain-no-tcache)
      run_env+=(MALLOC_CONF="tcache:false")
      ;;
  esac
  { time -p "${run_env[@]}" "$bin" "${args[@]}"; } >"$log" 2>&1 || true
  local secs status
  secs=$(parse_average "$log")
  status=$(crash_note "$log")
  echo "$config,$kernel,$graph,$NTHREADS,$run,${secs:-},$status"
}

max_existing_run() {
  local app_dir="$1" kernel="$2" graph="$3"
  local max_run=0 path base run
  shopt -s nullglob
  for tag in "${TAG_ARR[@]}"; do
    for path in "$app_dir/${kernel}.${graph}.t${NTHREADS}.${tag}.r"*.txt; do
      base="${path##*/}"
      if [[ "$base" =~ \.r([0-9]+)\.txt$ ]]; then
        run="${BASH_REMATCH[1]}"
        (( run > max_run )) && max_run="$run"
      fi
    done
  done
  shopt -u nullglob
  echo "$max_run"
}

max_existing_warmup() {
  local app_dir="$1" kernel="$2" graph="$3"
  local max_warmup=0 path base run
  shopt -s nullglob
  for tag in "${TAG_ARR[@]}"; do
    for path in "$app_dir/${kernel}.${graph}.t${NTHREADS}.${tag}.warmup"*.txt; do
      base="${path##*/}"
      if [[ "$base" =~ \.warmup([0-9]+)\.txt$ ]]; then
        run="${BASH_REMATCH[1]}"
        (( run > max_warmup )) && max_warmup="$run"
      fi
    done
  done
  shopt -u nullglob
  echo "$max_warmup"
}

ensure_graphs

for graph in $GRAPHS; do
  local_csv="${COMPARE_CSV:-$RESULTS_DIR/gapbs.${graph}.t${NTHREADS}.compare.csv}"
  if [[ ! -f "$local_csv" ]]; then
    echo "config,app,input,threads,run,time_s,status" >"$local_csv"
  fi
  for kernel in $KERNELS; do
    # cn902 OpenMP logs after the 2026-09-17 pinning advice live under pinned/.
    # Serial + t2–t16 kron22 are under nonpinned/. Override with RESULT_SUBDIR.
    if [[ "$MACHINE" == "cn902" ]]; then
      app_dir="$RESULTS_DIR/$kernel/$MACHINE/${RESULT_SUBDIR:-pinned}"
    elif [[ -n "${RESULT_SUBDIR:-}" ]]; then
      app_dir="$RESULTS_DIR/$kernel/$MACHINE/$RESULT_SUBDIR"
    else
      app_dir="$RESULTS_DIR/$kernel/$MACHINE"
    fi
    mkdir -p "$app_dir"
    existing_warmup=$(max_existing_warmup "$app_dir" "$kernel" "$graph")
    warmup_start=$((existing_warmup + 1))
    existing_run=$(max_existing_run "$app_dir" "$kernel" "$graph")
    run_start="$START"
    if (( existing_run >= run_start )); then
      run_start=$((existing_run + 1))
    fi
    run_end=$((run_start + RUNS - 1))
    if (( WARMUP > 0 || existing_run > 0 )); then
      echo "$kernel $graph t$NTHREADS: warmup$warmup_start, r$run_start"
    fi
    if [[ "$WARMUP" -gt 0 ]]; then
      echo "==== $kernel $graph warmup ===="
      for ((i = warmup_start; i < warmup_start + WARMUP; i++)); do
        for idx in "${!CONFIG_ARR[@]}"; do
          run_one "${CONFIG_ARR[$idx]}" "$kernel" "$graph" "${TAG_ARR[$idx]}" \
            "$app_dir/${kernel}.${graph}.t${NTHREADS}.${TAG_ARR[$idx]}.warmup${i}.txt" \
            "warmup$i" >/dev/null
        done
      done
    fi
    for ((i = run_start; i <= run_end; i++)); do
      for idx in "${!CONFIG_ARR[@]}"; do
        cfg="${CONFIG_ARR[$idx]}"
        name="${TAG_ARR[$idx]}"
        log="$app_dir/${kernel}.${graph}.t${NTHREADS}.${name}.r${i}.txt"
        echo "run $kernel $graph $name $i (through $run_end) -> $log"
        run_one "$cfg" "$kernel" "$graph" "$name" "$log" "$i" | tee -a "$local_csv"
      done
    done
  done
  echo
  echo "results -> $local_csv"
  column -t -s, "$local_csv" || true
done
