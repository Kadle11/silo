#!/bin/bash
# run.sh – Silo (dbtest) benchmark runner
# Mirrors apps/gups-bw/run-nocontrol.sh: same prologue/cleanup, same
# monitoring tools (mpstat, pgstat, optional bpftrace), same DAMON-steer
# integration via helpers.sh.
#
# Usage:
#   ./run.sh <type> <threads> [scale_factor] [runtime_secs] [variant] \
#            [numa_memory_gb] [prefix_dir] [damon_bw_mb_s] [damon_nr_kdamonds]
#
# Types:
#   0: NoTier   1: TPP   2: DAMON   3: Nomad   4: Colloid
#   6: ARMS     9: TIDE  10: Ripple-TPP        11: Ripple

set -o pipefail

export RIPPLE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SILODIR="$(cd "$(dirname "$0")" && pwd)"
RSTDIR="$SILODIR/results"
NODE_NAME=$(hostname | awk -F. '{print $1}')

export LSOC=0
export RSOC=1

MB_WARMUP=60

source "$RIPPLE_ROOT/scripts/helpers.sh"

# Per-policy knobs (preserved from the GUPS-BW no-control runner).
export TPP_DEMOTE_SCALE_FACTOR=500
export TPP_SCAN_SIZE_MB=512
export TPP_SCAN_PERIOD_MIN_MS=500
export TPP_SCAN_PERIOD_MAX_MS=500
export TPP_SCAN_DELAY_MS=100

export NOMAD_DEMOTE_SCALE_FACTOR=500
export NOMAD_SCAN_SIZE_MB=512
export NOMAD_SCAN_PERIOD_MIN_MS=500
export NOMAD_SCAN_PERIOD_MAX_MS=500
export NOMAD_SCAN_DELAY_MS=100

export RIPPLE_TPP_SCAN_SIZE_MB=16384

# --------------------------------------------------------------------------
# Args
# --------------------------------------------------------------------------
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <type> <threads> [scale_factor] [runtime_secs] [variant] [numa_memory_gb] [prefix_dir] [damon_bw_mb_s] [damon_nr_kdamonds]"
  echo ""
  echo "  type              Tier management policy"
  echo "  threads           Worker thread count (and CPU count for pinning)"
  echo "  scale_factor      dbtest --scale-factor (default: =threads)"
  echo "  runtime_secs      Benchmark runtime in seconds (default: 120)"
  echo "  variant           Silo workload variant: tpcc|ycsb (default: tpcc)"
  echo "  numa_memory_gb    dbtest --numa-memory in GiB (default: 80)"
  echo "  prefix_dir        Optional result directory prefix"
  echo "  damon_bw_mb_s     DAMON migrate bandwidth budget in MB/s (default: 16384)"
  echo "  damon_nr_kdamonds Number of kdamond workers (default: 16)"
  echo ""
  echo "Types:"
  for k in $(echo "${!sysmap[@]}" | tr ' ' '\n' | sort -n); do
    echo "    $k: ${sysmap[$k]}"
  done
  exit 1
fi

ttype=$1
pthreads=$2
SCALE_FACTOR=${3:-$pthreads}
RUNTIME=${4:-120}
SILO_VARIANT=${5:-tpcc}
NUMA_MEMORY_GB=${6:-80}
PREFIX_DIR=${7:-}
DAMON_BW_MB_S=${8:-16384}
DAMON_NR_KDAMONDS=${9:-16}

case "$SILO_VARIANT" in
  tpcc|ycsb) ;;
  *) echo "Invalid variant '$SILO_VARIANT' (expected tpcc|ycsb)"; exit 1 ;;
esac

DBTEST_BIN="$SILODIR/out-perf.masstree/benchmarks/dbtest"

# helpers.sh make_output_dir keys off $SIZE_MB; mirror NUMA_MEMORY_GB into it.
SIZE_MB=$((NUMA_MEMORY_GB * 1024))
TIME_SUFFIX=$(date +"%Y%m%d-%H%M%S")
DAMO_STEER_SCRIPT="$RIPPLE_ROOT/tier-sys/damon/damo-steer.sh"

all_pids=()

# --------------------------------------------------------------------------
# Validate
# --------------------------------------------------------------------------
cps=$(cores_per_socket)
if (( pthreads < 1 || pthreads > cps )); then
  echo "threads[$pthreads] out of range 1..${cps}"
  exit 1
fi

if (( ttype == 2 )); then
  if ! [[ "$DAMON_BW_MB_S" =~ ^[0-9]+$ && "$DAMON_NR_KDAMONDS" =~ ^[0-9]+$ ]]; then
    echo "For DAMON type, damon_bw_mb_s and damon_nr_kdamonds must be positive integers"
    exit 1
  fi
fi

[[ -e "$DBTEST_BIN" ]]        || { echo "dbtest binary not found: $DBTEST_BIN"; exit 1; }
[[ -e "$DAMO_STEER_SCRIPT" ]] || { echo "DAMON steering script not found: $DAMO_STEER_SCRIPT"; exit 1; }
export DAMO_STEER_SCRIPT

# --------------------------------------------------------------------------
# Topology — SMT off so numactl reports physical cores only.
# --------------------------------------------------------------------------
disable_smt
LSOC_CORES=$(node_cores "$LSOC")
RSOC_CORES=$(node_cores "$RSOC")
export RSOC_CORES

MB_CORES=$(core_slice "$LSOC_CORES" 2 $((pthreads + 1)))

DAMON_CORES=$(core_slice "$LSOC_CORES" $((pthreads + 2)))
if (( ttype == 2 )) && [[ -z "$DAMON_CORES" ]]; then
  echo "No remaining cores to pin DAMON kdamonds after benchmark core allocation"
  exit 1
fi
export DAMON_CORES DAMON_BW_MB_S DAMON_NR_KDAMONDS

enable_smt

echo "=== Silo (dbtest) Run Configuration ==="
echo "  type:             $ttype (${sysmap[$ttype]})"
echo "  threads:          $pthreads  (cpus $MB_CORES)"
echo "  variant:          $SILO_VARIANT"
echo "  binary:           $DBTEST_BIN"
echo "  scale_factor:     $SCALE_FACTOR"
echo "  numa_memory:      ${NUMA_MEMORY_GB}G"
echo "  runtime:          $RUNTIME s"
if (( ttype == 2 )); then
  echo "  damon_bw_mb_s:    $DAMON_BW_MB_S"
  echo "  damon_nr_kdamonds:$DAMON_NR_KDAMONDS"
  echo "  damon_pin_cores:  $DAMON_CORES"
fi
echo "======================================="

# --------------------------------------------------------------------------
# Prologue dispatch
# --------------------------------------------------------------------------
prologue() {
  prologue_base
  case "$ttype" in
    1)  setup_tpp        ;;
    2)  setup_damon      ;;
    3)  setup_nomad      ;;
    4)  setup_colloid    ;;
    6)  setup_arms       ;;
    9)  setup_tide       ;;
    10) setup_ripple_tpp ;;
    11) setup_ripple     ;;
  esac
}

trap "cleanup_base; exit" SIGINT SIGTERM

# --------------------------------------------------------------------------
# Main run
# --------------------------------------------------------------------------
run() {
  local output_dir
  output_dir=$(make_output_dir "silo-${SILO_VARIANT}")

  local perff="${output_dir}/perf.log"
  local pgf="${output_dir}/pgstat.log"
  local outf="${output_dir}/out.log"
  local timef="${output_dir}/time.log"
  local sarf="${output_dir}/sar.log"
  local pgmapf="${output_dir}/pgmap.log"
  local zonef="${output_dir}/zone.log"
  local minorf="${output_dir}/minor_faults.log"

  truncate_logs "$outf" "$pgf" "$perff" "$timef" "$sarf" "$pgmapf" "$zonef" "$minorf"

  {
    echo "type=$ttype (${sysmap[$ttype]})"
    echo "bench=silo"
    echo "variant=$SILO_VARIANT"
    echo "binary=$DBTEST_BIN"
    echo "threads=$pthreads"
    echo "scale_factor=$SCALE_FACTOR"
    echo "runtime=$RUNTIME"
    echo "numa_memory_gb=$NUMA_MEMORY_GB"
    echo "cpus=$MB_CORES"
    if [[ $ttype == 2 || $ttype == 11 || $ttype == 9 || $ttype == 6 ]]; then
      echo "damon_local_numa=$LSOC"
      echo "damon_remote_numa=$RSOC"
      echo "damon_bw_mb_s=$DAMON_BW_MB_S"
      echo "damon_nr_kdamonds=$DAMON_NR_KDAMONDS"
      echo "damon_pin_cores=$DAMON_CORES"
      echo "damon_steer_script=$DAMO_STEER_SCRIPT"
    fi
    echo "timestamp=$TIME_SUFFIX"
  } > "${output_dir}/config.txt"

  echo "START ..."
  prologue

  local start_time
  start_time=$(date +%s)

  start_mpstat "$sarf"

  # start_bpftrace "$RIPPLE_ROOT/scripts/profile_stalls-ipis.bt" "$minorf"
  # start_bpftrace "$RIPPLE_ROOT/scripts/profile_migr_pte.bt"     "$minorf"
  # BPFTRACE_MAX_MAP_KEYS=4194304 \
  #   start_bpftrace "$RIPPLE_ROOT/scripts/profile_migr_timing.bt" "$minorf"

  local nomad_flag=0
  [[ $ttype == 3 || $ttype == 7 ]] && nomad_flag=1
  start_pgstat "$pgf" "$zonef" "$pgmapf" "$nomad_flag"

  echo "Running silo dbtest ($SILO_VARIANT) ..."

  set -x
  numactl -C "$MB_CORES" $DBTEST_BIN \
      --verbose \
      --bench "$SILO_VARIANT" \
      --num-threads "$pthreads" \
      --scale-factor "$SCALE_FACTOR" \
      --runtime "$RUNTIME" \
      --parallel-loading \
      --numa-memory "${NUMA_MEMORY_GB}G" \
      --pinned-cpus "$MB_CORES" \
  > "$outf" 2>&1 &
  set +x


  local silo_pid=$!
  
  track_pid "$silo_pid"

  show_progress "$RUNTIME" "${sysmap[$ttype]}" &
  track_pid $!

  if [[ $ttype == 2 || $ttype == 11 || $ttype == 9 || $ttype == 6 ]]; then
    sleep "$MB_WARMUP"
    start_damon_steer "$output_dir" --promote-only
  fi

  wait "$silo_pid"

  local end_time
  end_time=$(date +%s)
  echo "Elapsed time: $((end_time - start_time)) seconds" | tee "$timef"

  cleanup_base
  echo "Results written to: ${output_dir}"
}

main() {
  run
}

main
echo "DONE"
