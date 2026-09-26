#!/usr/bin/env bash
# Stand-in for `pmarl train` in tests. Takes the same flags and reads its
# behaviour from the config: "fake_sleep" (seconds), "fake_exit_code".
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

echo "training $name from $config"
mkdir -p "$base_dir/$name"
echo '{"step": 0, "algo/total_loss": 1.0}' >"$base_dir/$name/logs.jsonl"
sleep "$sleep_for"
echo "done"
exit "$exit_code"
