#!/usr/bin/env bash
# Collect jemalloc malloc/free stats for the 3 GAPBS configs.
# Counts come from MALLOC_CONF=stats_print (merged arenas, no per-arena dump).
#
# Usage:
#   ./malloc_stats_gapbs.sh
#   GRAPHS="kron22" KERNELS="bfs pr" NTHREADS_LIST="16 1" ./malloc_stats_gapbs.sh
set -euo pipefail

RESULTS_DIR="${RESULTS_DIR:-$HOME/gapbs-results}"
MACHINE="${MACHINE:-h0}"
OUT_DIR="${OUT_DIR:-$RESULTS_DIR/malloc-stats/$MACHINE}"
GRAPHS="${GRAPHS:-kron22 urand22}"
KERNELS="${KERNELS:-bfs cc pr bc sssp tc}"
GRAPH_DIR="${GRAPH_DIR:-$RESULTS_DIR/graphs}"
NTHREADS_LIST="${NTHREADS_LIST:-16}"
CONFIGS=(clang-plain clang-plainje clang-chonk)
TAGS=(plain plainje chonk)

# Compact table dump: disable per-arena / bins / mutex / extents / hpa / destroyed.
export MALLOC_CONF="stats_print:true,stats_print_opts:abxehd"

mkdir -p "$OUT_DIR"

die() { echo "error: $*" >&2; exit 1; }

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

parse_stats() {
  python3 - "$1" <<'PY'
import json, re, sys
text = open(sys.argv[1], errors="replace").read()
i = text.find('{"jemalloc":')
if i >= 0:
    obj, _ = json.JSONDecoder().raw_decode(text, i)
    arenas = obj["jemalloc"].get("stats.arenas") or {}
    used = arenas["merged"] if "merged" in arenas else next(iter(arenas.values()))
    small, large = used.get("small") or {}, used.get("large") or {}
    def add(k):
        return small.get(k, 0) + large.get(k, 0)
    print(f"{add('nrequests')},{add('nmalloc')},{add('ndalloc')},{add('nfills')},{add('nflushes')},{add('allocated')},{used.get('uptime_ns','')}")
    sys.exit(0)
m = re.search(r"Merged arena.*?(?=Destroyed|--- End jemalloc|\Z)", text, re.S)
block = m.group(0) if m else text
uptime = ""
um = re.search(r"uptime:\s+(\d+)", block)
if um:
    uptime = um.group(1)
tot = re.search(
    r"^\s*total:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$",
    block, re.M)
if not tot:
    print(",,,,,,")
    sys.exit(0)
allocated, nmalloc, ndalloc, nrequests, nfill, nflush = tot.groups()
print(f"{nrequests},{nmalloc},{ndalloc},{nfill},{nflush},{allocated},{uptime}")
PY
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
  local config="$1" tag="$2" kernel="$3" graph="$4" nthreads="$5"
  local bin="$RESULTS_DIR/bin/$tag/$kernel"
  [[ -x "$bin" ]] || die "missing $bin; run ./build_gapbs.sh"
  local log="$OUT_DIR/${kernel}.${graph}.t${nthreads}.${tag}.stats.txt"
  echo "stats $kernel $graph $tag t$nthreads -> $log"
  local -a args
  read -r -a args <<<"$(kernel_args "$kernel" "$graph")"
  export OMP_NUM_THREADS="$nthreads"
  { time -p "$bin" "${args[@]}"; } >"$log" 2>&1 || true
  local secs status stats
  secs=$(parse_average "$log")
  status=$(crash_note "$log")
  stats=$(parse_stats "$log")
  echo "$config,$tag,$kernel,$graph,$nthreads,${secs:-},$status,$stats" | tee -a "$CSV"
}

CSV="$OUT_DIR/malloc.stats.csv"
echo "config,tag,app,input,threads,time_s,status,nrequests,nmalloc,ndalloc,nfill,nflush,allocated,uptime_ns" >"$CSV"

for n in $NTHREADS_LIST; do
  for graph in $GRAPHS; do
    for kernel in $KERNELS; do
      for i in 0 1 2; do
        run_one "${CONFIGS[$i]}" "${TAGS[$i]}" "$kernel" "$graph" "$n"
      done
    done
  done
done

echo
echo "results -> $CSV"
column -t -s, "$CSV" || true
