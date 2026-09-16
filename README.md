# GAPBS results

Timing logs and scripts for GAP Benchmark Suite runs comparing three allocator / CHONK configs:

| Tag | Compiler | Allocator | Meaning |
|---|---|---|---|
| `plain` | `clang-plain++` | `~/jemalloc-og` | **baseline** |
| `plainje` | `clang-plain++` | `~/jemalloc` | **chonk no analysis** |
| `chonk` | `clang-chonky++` | `~/jemalloc` | **chonk** |

This repo is the **harness and results**, not the compiler or the input graphs.

- Per-kernel run logs: `<kernel>/<machine>/` (h0 logs from the first campaign are in-tree)
- Cross-kernel CSVs at the repo root: `gapbs.<graph>.t<N>.compare.csv`
- Charts: `python3 plot_gapbs.py` writes `graphs-out/`

Times are GAPBS **Average Time** (kernel only), not wall-clock graph load.

## What you still need on the new machine

GitHub cannot hold these (too large, or host-specific):

| Tree | Why |
|---|---|
| `~/llvm-19-build` | ~1.5G Clang 19 with `clang-plain++` / `clang-chonky++` |
| `~/jemalloc`, `~/jemalloc-og` | cset-aware vs baseline jemalloc |
| `graphs/*.sg` | `kron22.wsg` is ~1G; regenerate instead |

If this host already ran the PARSEC CHONK campaign, the Clang and jemalloc trees should already be at those paths. You also need system **GCC 13** (`/usr/lib/gcc/x86_64-linux-gnu/13`) and **libgomp** (`-fopenmp=libgomp`).

GAPBS sources are upstream, not this repo:

```bash
git clone git@github.com:sbeamer/gapbs.git ~/gapbs
# or: git clone https://github.com/sbeamer/gapbs.git ~/gapbs
```

## Replicate on another machine (e.g. cn902)

No rsync. Clone this repo and rebuild.

```bash
git clone git@github.com:VarsosEmblem/gapbs-results.git ~/gapbs-results
git clone git@github.com:sbeamer/gapbs.git ~/gapbs

ls ~/llvm-19-build/bin/clang-plain++ ~/llvm-19-build/bin/clang-chonky++
ls ~/jemalloc/lib/libjemalloc.so ~/jemalloc-og/lib/libjemalloc.so
ls /usr/lib/gcc/x86_64-linux-gnu/13
```

If GCC is not 13:

```bash
export GCC_INSTALL_DIR=/usr/lib/gcc/x86_64-linux-gnu/<N>
```

Build three configs into `bin/<tag>/` (do not copy `bin/` from another host):

```bash
cd ~/gapbs-results
./build_gapbs.sh
```

Smoke, then the kron22 / 16-thread campaign (graphs are created on first run):

```bash
export MACHINE=cn902   # default is h0; must set this so logs do not mix

GRAPHS=kron10 KERNELS=bfs RUNS=1 WARMUP=0 NTHREADS=2 ./compare_gapbs.sh

GRAPHS=kron22 KERNELS="bfs cc pr bc sssp tc" \
  NTHREADS=16 RUNS=5 WARMUP=1 ./compare_gapbs.sh

python3 plot_gapbs.py
```

Then commit and push the new `<kernel>/cn902/` logs and `gapbs.kron22.t16.compare.csv`. If h0 already has a CSV of that name, rename the cn902 file (e.g. `gapbs.kron22.t16.cn902.compare.csv`) before merging, or keep results on a branch.

## Scripts

| Script | Role |
|---|---|
| `build_gapbs.sh` | Build `plain` / `plainje` / `chonk` |
| `compare_gapbs.sh` | Interleaved runs, write CSV |
| `plot_gapbs.py` | Runtime / speedup / geomean PNGs |
| `malloc_stats_gapbs.sh` | jemalloc `stats_print` |

Useful knobs: `MACHINE`, `GRAPHS`, `KERNELS`, `NTHREADS`, `RUNS`, `WARMUP`, `START`, `GCC_INSTALL_DIR`, `LLVM_DIR`, `GAPBS_DIR`, `RESULTS_DIR`, `OPENMP=0` (serial).
