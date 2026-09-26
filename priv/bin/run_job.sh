#!/usr/bin/env bash
# Runs one training job, detached from the dashboard so that runs survive
# dashboard restarts. The dashboard starts this through `setsid --fork`, so this
# script leads a new process group: `kill -- -PID` stops the whole run.
#
# usage: run_job.sh JOB_DIR WORK_DIR COMMAND [ARGS...]
#
# Files written to JOB_DIR:
#   pid          this script's PID, which is also the process group ID
#   output.log   combined stdout/stderr of COMMAND
#   exit_code    COMMAND's exit status, written once it finishes
#
# A pid with no exit_code after the process is gone means the run was killed
# (cancelled, OOM killer, reboot...).
set -u

# Let go of the dashboard's stdio right away, otherwise the dashboard's
# System.cmd call would block until the run finishes.
exec </dev/null >/dev/null 2>&1

job_dir=$1
work_dir=$2
shift 2

# Write-then-rename so the dashboard never reads a partially written file.
echo $$ >"$job_dir/pid.tmp" && mv "$job_dir/pid.tmp" "$job_dir/pid"

if cd "$work_dir"; then
  "$@" >"$job_dir/output.log" 2>&1
  code=$?
else
  echo "run_job.sh: cannot cd to $work_dir" >"$job_dir/output.log"
  code=127
fi

echo "$code" >"$job_dir/exit_code.tmp" && mv "$job_dir/exit_code.tmp" "$job_dir/exit_code"
