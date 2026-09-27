#!/usr/bin/env bash
# Stand-in for `pmarl record` in tests. Takes the same arguments as the
# dashboard passes, after optional behaviour flags: `--fake-sleep SECONDS`
# (before recording), `--fake-exit-code N` (fail before writing anything).
set -u

sleep_for=0
exit_code=0
while [ $# -gt 0 ]; do
  case $1 in
    --fake-sleep) sleep_for=$2; shift 2 ;;
    --fake-exit-code) exit_code=$2; shift 2 ;;
    --base-dir) shift 2 ;;
    --out-dir) out_dir=$2; shift 2 ;;
    -*) echo "unexpected argument: $1"; exit 2 ;;
    *) name=$1; shift ;;
  esac
done

echo "Loading $name"
sleep "$sleep_for"
if [ "$exit_code" != 0 ]; then
  echo "ValueError: fake failure"
  exit "$exit_code"
fi

mkdir -p "$out_dir"
for task in 0 1; do
  echo "Recording task $((task + 1))/2: task_$task (1 agents, 2 steps, 4x4)"
  echo "  task_$task: step 2/2"
  printf 'fake video %s' "$task" >"$out_dir/task-$task.mp4"
done
cat >"$out_dir/manifest.json" <<JSON
{"run": "$name", "checkpoint_step": 7, "seed": 0, "created_at": "2026-09-26T12:00:00Z",
 "videos": [
   {"task": "task_0", "file": "task-0.mp4", "width": 4, "height": 4},
   {"task": "task_1", "file": "task-1.mp4", "width": 4, "height": 4}
 ]}
JSON
