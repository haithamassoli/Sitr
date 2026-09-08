#!/bin/bash
# M1-T08 system cost (docs/spike/system.md). Runs build/Sitr.app for <seconds> with the pipeline metrics on, next to a stimulus
# window in a second process (browsing | video) or nothing at all (static: the desktop is left alone, no window of ours is
# opened), samples the Sitr process once a second with ps and prints: CPU mean / p95 (% of one core), RSS max, the pipeline's
# per-stage p50/p95, the skipped-frame ratio and the thermal state.
#   scripts/measure-system.sh <browsing|video|static|paused|disabled> <seconds>
#   SITR_CAPTURE_SIDE=1920 SITR_FPS=30 scripts/measure-system.sh video 120     # CaptureSession dev overrides pass through
#   SITR_PERF_LEGACY=1 scripts/measure-system.sh browsing 120                  # M4-T09 A/B: the pre-M4-T09 per-frame behaviour
# Uses an isolated preferences/rules suite; video/browsing are invalid if no person covers were produced.
# SITR_STYLE=gaussian|pixelate|solid, SITR_HIDDEN_SET=everyone|women|men, SITR_RULE_MODE=blur|curtain.
# Needs scripts/build-app.sh (release app) and swift build (debug stimulus).
# Screen Recording is inherited from the shell (docs/dev.md). Exits on its own, kills both processes on any exit; the logs
# hold timings and counts only. GPU / ANE utilisation needs `sudo powermetrics --samplers gpu_power,ane_power`: pending.
# ponytail: ps %cpu on macOS is a decaying average of the process (per core, so already "% of one core"); the exact mean comes
# from the cputime delta over the same window. Steady state = samples from t ≥ 10 s (model load + ANE warm-up excluded).
set -uo pipefail
cd "$(dirname "$0")/.."
MODE=${1:?usage: measure-system.sh <browsing|video|static|paused|disabled> <seconds>}
RUN_SECONDS=${2:?usage: measure-system.sh <browsing|video|static|paused|disabled> <seconds>}
case $MODE in browsing|video|static|paused|disabled) ;; *) echo "unknown mode $MODE (browsing|video|static)"; exit 2;; esac
APP=build/Sitr.app/Contents/MacOS/Sitr
STIM=.build/debug/Sitr
[ -x "$APP" ] || { echo "missing $APP: run scripts/build-app.sh --debug"; exit 1; }
[ "$MODE" = static ] || [ -x "$STIM" ] || { echo "missing $STIM: run swift build"; exit 1; }
uuid() { dwarfdump --uuid "$1" 2>/dev/null | awk '{print $2}'; }  # codesign keeps LC_UUID, so this tells which build was bundled
BUILD=unknown
[ "$(uuid "$APP")" = "$(uuid .build/debug/Sitr)" ] && BUILD=debug
[ "$(uuid "$APP")" = "$(uuid .build/release/Sitr)" ] && BUILD=release
OUT=$(mktemp -d "${TMPDIR:-/tmp}/sitr-system.XXXXXX")
APP_PID=; STIM_PID=
cleanup() { for p in $APP_PID $STIM_PID; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
therm() { pmset -g therm | grep -E 'CPU_|No thermal' | sed -E 's/^[[:space:]]+//; s/Note: //' | paste -sd ';' - | tr ' ' '_'; }
# nearest-rank percentile of the numbers on stdin (same rounding as the Swift rigs); "-" when empty
pct() { sort -n | awk -v p="$1" '{a[NR]=$1} END { if (NR == 0) { print "-"; exit } i = int((NR - 1) * p + 0.5) + 1; printf "%.1f\n", a[i] }'; }

echo "system_run mode=$MODE seconds=$RUN_SECONDS build=$BUILD side=${SITR_CAPTURE_SIDE:-1280} fps=${SITR_FPS:-15} perf_legacy=${SITR_PERF_LEGACY:-0} load1_start=$(load1) therm_start=$(therm)"
OPTIONS=(--selftest system --seconds "$RUN_SECONDS" --style "${SITR_STYLE:-gaussian}" --hide "${SITR_HIDDEN_SET:-everyone}" --rule "${SITR_RULE_MODE:-blur}")
case $MODE in
  browsing|video) OPTIONS+=(--require-covers);;
  paused) OPTIONS+=(--paused);;
  disabled) OPTIONS+=(--disabled);;
esac
SITR_METRICS=1 "$APP" "${OPTIONS[@]}" >"$OUT/app.log" 2>&1 &
APP_PID=$!
T0=$(date +%s)
if [ "$MODE" != static ]; then
  sleep 3  # capture connects and the models load first; the stimulus quits ~2 s before the app
  STIM_MODE=$MODE
  case $MODE in paused|disabled) STIM_MODE=video;; esac
  "$STIM" --selftest stimulus --mode "$STIM_MODE" --seconds $((RUN_SECONDS - 5)) >"$OUT/stim.log" 2>&1 &
  STIM_PID=$!
fi
# One sample per second: t, %cpu, rss KB, cputime, load1, replayd %cpu (the ScreenCaptureKit server works for us but is not our
# process, so ps on our PID alone would under-count the capture cost; WindowServer is shared with everything else and not sampled)
: >"$OUT/samples"
while kill -0 "$APP_PID" 2>/dev/null; do
  RC=$(ps -o %cpu= -p "$(pgrep -x replayd | head -1 || echo 0)" 2>/dev/null | tr -d ' ')
  ps -o %cpu=,rss=,cputime= -p "$APP_PID" 2>/dev/null | awk -v t=$(( $(date +%s) - T0 )) -v l="$(load1)" -v r="${RC:-0}" 'NF == 3 { print t, $1, $2, $3, l, r }' >>"$OUT/samples"
  sleep 1
done
wait "$APP_PID" 2>/dev/null; APP_EXIT=$?
[ -n "$STIM_PID" ] && wait "$STIM_PID" 2>/dev/null
APP_PID=; STIM_PID=
LEFT=$(pgrep -fl 'build/Sitr.app/Contents/MacOS/Sitr|selftest stimulus' | wc -l | tr -d ' ')

# CPU: steady-state samples (t ≥ 10); exact mean from the cputime delta over the same window
awk '$1 >= 10' "$OUT/samples" >"$OUT/steady"
N=$(wc -l <"$OUT/steady" | tr -d ' ')
CPU_MEAN=$(awk '{s += $2} END { if (NR) printf "%.1f", s / NR; else print "-" }' "$OUT/steady")
CPU_P95=$(awk '{print $2}' "$OUT/steady" | pct 0.95)
CPU_MAX=$(awk 'BEGIN { m = 0 } $2 > m { m = $2 } END { printf "%.1f", m }' "$OUT/steady")
CPU_EXACT=$(awk 'function secs(s,  a, n, i, v) { n = split(s, a, ":"); v = 0; for (i = 1; i <= n; i++) v = v * 60 + a[i]; return v }
  NR == 1 { t0 = $1; c0 = secs($4) } { t1 = $1; c1 = secs($4) } END { if (NR > 1 && t1 > t0) printf "%.1f", (c1 - c0) / (t1 - t0) * 100; else print "-" }' "$OUT/steady")
STARTUP_MAX=$(awk 'BEGIN { m = 0 } $1 < 10 && $2 > m { m = $2 } END { printf "%.1f", m }' "$OUT/samples")
RSS_MAX=$(awk 'BEGIN { m = 0 } $3 > m { m = $3 } END { printf "%d", m / 1024 }' "$OUT/samples")
LOAD_STATS=$(awk 'NR == 1 { lo = $5; hi = $5 } { s += $5; if ($5 < lo) lo = $5; if ($5 > hi) hi = $5 } END { if (NR) printf "%.1f/%.1f/%.1f", lo, s / NR, hi; else print "-" }' "$OUT/samples")
REPLAYD_MEAN=$(awk '{s += $6} END { if (NR) printf "%.1f", s / NR; else print "-" }' "$OUT/steady")
REPLAYD_P95=$(awk '{print $6}' "$OUT/steady" | pct 0.95)
echo "system_cpu mode=$MODE build=$BUILD side=${SITR_CAPTURE_SIDE:-1280} fps=${SITR_FPS:-15} perf_legacy=${SITR_PERF_LEGACY:-0} samples=$N cpu_mean=$CPU_MEAN cpu_p95=$CPU_P95 cpu_max=$CPU_MAX cpu_exact_mean=$CPU_EXACT startup_cpu_max=$STARTUP_MAX rss_max_mb=$RSS_MAX replayd_cpu_mean=$REPLAYD_MEAN replayd_cpu_p95=$REPLAYD_P95 load1_min/mean/max=$LOAD_STATS app_exit=$APP_EXIT leftover_processes=$LEFT therm_end=$(therm)"

# Pipeline metrics: every 5 s window with t ≥ 10 → median of the window p50s and p95s (and the worst p95) per stage
grep -E '^pipeline display=[0-9]+ (detector=|first_frame)' "$OUT/app.log"
grep -E '^pipeline display=[0-9]+ t=' "$OUT/app.log" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^t=/) { split($i, a, "="); if (a[2] + 0 >= 10) print } }' >"$OUT/windows"
W=$(wc -l <"$OUT/windows" | tr -d ' ')
STAGES=""
for stage in detect_ms classify_ms render_ms commit_ms e2e_ms; do
  grep -o "$stage=[0-9.]*/[0-9.]*" "$OUT/windows" | sed "s/$stage=//" >"$OUT/$stage"
  p50=$(cut -d/ -f1 "$OUT/$stage" | pct 0.5); p95=$(cut -d/ -f2 "$OUT/$stage" | pct 0.5); worst=$(cut -d/ -f2 "$OUT/$stage" | pct 1.0)
  STAGES="$STAGES $stage=$p50/$p95(worst_p95=$worst)"
done
LAST=$(tail -1 "$OUT/windows")
field() { echo "$LAST" | grep -o "$1=[^ ]*" | cut -d= -f2; }
IN=$(field in); SKIPPED=$(field skipped)
RATIO=$(awk -v i="${IN:-0}" -v s="${SKIPPED:-0}" 'BEGIN { if (i + s > 0) printf "%.3f", s / (i + s); else print "-" }')
LAYERS_MAX=$(grep -o 'layers=[0-9]*' "$OUT/windows" | cut -d= -f2 | pct 1.0)
RSS_PIPE=$(grep -o 'rss_mb=[0-9]*' "$OUT/windows" | cut -d= -f2 | pct 1.0)
echo "system_pipeline mode=$MODE windows=$W frames_in=${IN:--} skipped=${SKIPPED:--} skipped_ratio=$RATIO layers_max=$LAYERS_MAX rss_mb_max=$RSS_PIPE$STAGES"
# M4-T09 per-frame work (cumulative counters on the last window ÷ frames processed): face crops classified, covers rendered,
# covers that reused the previous frame's pixels, detections skipped because nothing detectable had changed.
OUTF=$(field out); CROPS=$(field crops); RENDERS=$(field renders); REUSES=$(field reuses); DSKIP=$(field detect_skips)
per() { awk -v a="${1:-0}" -v b="${OUTF:-0}" 'BEGIN { if (b > 0) printf "%.2f", a / b; else print "-" }'; }
echo "system_frame mode=$MODE perf_legacy=${SITR_PERF_LEGACY:-0} frames_out=${OUTF:--} crops_per_frame=$(per "$CROPS") renders_per_frame=$(per "$RENDERS") reuses_per_frame=$(per "$REUSES") detect_skips=${DSKIP:--} face_skips=$(field face_skips) apply_skips=$(field apply_skips) applies=$(field applies) reuse_blocked=$(field reuse_blocked)"
tail -2 "$OUT/windows"
[ -f "$OUT/stim.log" ] && grep -E '^(stimulus|selftest_)' "$OUT/stim.log"
grep -E '^(system_configuration|system_valid|selftest_system)' "$OUT/app.log"
echo "system_logs dir=$OUT"
[ "$APP_EXIT" = 0 ] && [ "$LEFT" = 0 ] && grep -q '^system_valid=true' "$OUT/app.log"
