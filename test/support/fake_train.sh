#!/usr/bin/env bash
# Stand-in for `pmarl train` in tests. Takes the same flags and reads its
# behaviour from the config: "fake_steps" (metric rows to write, 0.05s
# apart), "fake_sleep" (seconds, after the steps), "fake_exit_code".
set -u

while [ $# -gt 0 ]; do
  case $1 in
    --config) config=$2; shift 2 ;;
    --base-dir) base_dir=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    *) echo "unexpected argument: $1"; exit 2 ;;
  esac
done

setting() { grep -o "\"$1\": *[0-9.]*" "$config" | grep -o '[0-9.]*$'; }
sleep_for=$(setting fake_sleep || echo 0)
exit_code=$(setting fake_exit_code || echo 0)
steps=$(setting fake_steps || echo 1)

echo "training $name from $config"
mkdir -p "$base_dir/$name"
# Like jaxrl's JsonLogger: one row per update, flushed as it goes.
: >"$base_dir/$name/logs.jsonl"
for ((step = 0; step < steps; step++)); do
  echo "{\"step\": $step, \"algo/total_loss\": $((100 - step)).5}" >>"$base_dir/$name/logs.jsonl"
  echo "step: $step"
  if ((step < steps - 1)); then sleep 0.05; fi
done
sleep "$sleep_for"
echo "done"
exit "$exit_code"
