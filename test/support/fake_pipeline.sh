#!/usr/bin/env bash
# Stand-in for `valm pipeline` in tests. Takes the same arguments as the
# dashboard passes (CONFIG --run-id NAME --base-dir DIR). Like the real
# pipeline, a PPO config first writes a value warmup stage to NAME-value,
# then the RL stage to NAME; anything else only writes NAME. Each stage logs
# "fake_steps" rows (from the config, default 1), 0.05s apart.
set -u

config=$1
shift
while [ $# -gt 0 ]; do
  case $1 in
    --run-id) name=$2; shift 2 ;;
    --base-dir) base_dir=$2; shift 2 ;;
    *) echo "unexpected argument: $1"; exit 2 ;;
  esac
done

steps=$(grep -o '"fake_steps": *[0-9]*' "$config" | grep -o '[0-9]*$' || echo 1)

stage() {
  local dir=$base_dir/$1 key=$2
  echo "stage $1"
  mkdir -p "$dir"
  : >"$dir/logs.jsonl"
  for ((step = 0; step < steps; step++)); do
    echo "{\"step\": $step, \"$key.mean\": $step.5, \"$key.max\": $((step + 1)).0}" >>"$dir/logs.jsonl"
    sleep 0.05
  done
}

if grep -q '"type": *"ppo"' "$config"; then
  stage "$name-value" value_loss
fi
stage "$name" rewards
echo "done"
