#!/usr/bin/env bash
#
# Runs every non-deprecated First Responder Kit script against a throwaway SQL
# Server, twice: once with the base branch's copies and once with the pull
# request's, then reports what changed.
#
# Before issue #4046 this script installed only the changed sp_*.sql and ran it
# with @VersionCheckMode = 1 -- an unconditional early RETURN -- so no check body
# ever executed and runtime breakage passed green. See PR #4045 for two bugs that
# did exactly that.
#
# Two outcomes, deliberately different (issue #4046, decision 1A):
#   * A SQL error this branch introduces FAILS the build.
#   * A difference in sp_Blitz's findings is PRINTED for a human and does not
#     fail the build, because changing a finding is often the point of the PR.
#
set -Eeuo pipefail

: "${SQLCMDSERVER:=tcp:127.0.0.1,1433}"
: "${SQLCMDUSER:=sa}"
: "${SQLCMDPASSWORD:?SQLCMDPASSWORD must be set}"
: "${SQLCMD:=sqlcmd}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SEED_SQL="$SCRIPT_DIR/smoke-test-seed.sql"
MATRIX_SQL="$SCRIPT_DIR/smoke-test-matrix.sql"

# Every non-deprecated script in the kit. sp_BlitzUpdate is deliberately absent:
# it rewrites the procs mid-run, which would invalidate every later step and the
# base-vs-head comparison (issue #4046, decision 4).
KIT_SCRIPTS=(
  "sp_Blitz.sql"
  "sp_BlitzAnalysis.sql"
  "sp_BlitzBackups.sql"
  "sp_BlitzCache.sql"
  "sp_BlitzFirst.sql"
  "sp_BlitzIndex.sql"
  "sp_BlitzLock.sql"
  "sp_BlitzWho.sql"
  "sp_DatabaseRestore.sql"
  "sp_ineachdb.sql"
  "sp_kill.sql"
  "OptionalScripts/sp_BlitzPlanCompare.sql"
)

# -I turns QUOTED_IDENTIFIER ON. sqlcmd defaults it OFF, and a procedure
# captures the setting in force when it is created, so without this the
# sp_BlitzFirst and sp_BlitzLock code paths that build indexed/XML expressions
# die at runtime with Msg 1934. Every real client (SSMS, .NET, ODBC) has it ON,
# so OFF was testing a configuration no user actually runs.
SQLCMD_ARGS=(
  -S "$SQLCMDSERVER"
  -U "$SQLCMDUSER"
  -P "$SQLCMDPASSWORD"
  -C
  -b
  -I
  -r 1
  -l 60
  -t 600
)

run_query() {
  "$SQLCMD" "${SQLCMD_ARGS[@]}" -d master -Q "$1"
}

run_file() {
  "$SQLCMD" "${SQLCMD_ARGS[@]}" -d master -i "$1"
}

# Single bare value, no headers or row counts. run_query cannot do this: it only
# forwards "$1", so any extra sqlcmd flags handed to it are silently dropped.
run_scalar() {
  "$SQLCMD" "${SQLCMD_ARGS[@]}" -d master -h -1 -W -Q "$1" 2>/dev/null \
    | sed '/^$/d;/rows affected/d' \
    | head -1 \
    | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Wait for the container
# ---------------------------------------------------------------------------
wait_for_sql_server() {
  echo "Waiting for SQL Server to accept connections..."
  for attempt in {1..90}; do
    if run_query "SET NOCOUNT ON; SELECT 1 AS ready;" >/dev/null 2>&1; then
      echo "SQL Server is ready."
      run_query "SET NOCOUNT ON; SELECT @@VERSION;"
      return 0
    fi

    if [[ "$attempt" -eq 90 ]]; then
      echo "::error::SQL Server did not become ready in time." >&2
      return 1
    fi

    sleep 2
  done
}

# ---------------------------------------------------------------------------
# Hold off until the instance has been up longer than a minute.
#
# sp_Blitz CheckID 152 divides by @MsSinceWaitsCleared, which is
# DATEDIFF(MINUTE, create_date, CURRENT_TIMESTAMP) * 60000.0 and is therefore 0
# for the instance's first minute. Its zero-guard sits inside a branch that
# cannot be taken while the value is 0, so sp_Blitz aborts with a divide-by-zero
# -- see issue #4048, which tracks the fix.
#
# That is a real bug, but it is not one this comparison can measure: it depends
# on how long the container took to start, so it fires on whichever pass happens
# to run first and shows up as a spurious base-vs-head difference. Waiting the
# window out keeps the two passes comparable. Remove this once #4048 is fixed.
#
# The value must parse as a number greater than zero. Anything else -- an empty
# result, a header line, an error -- means we have not confirmed the window has
# passed, so keep waiting rather than assuming the best.
# ---------------------------------------------------------------------------
wait_for_wait_stats() {
  local uptime_minutes

  echo "Waiting for the instance to pass one minute of uptime (issue #4048)..."
  for attempt in {1..40}; do
    uptime_minutes="$(run_scalar "SET NOCOUNT ON;
SELECT DATEDIFF(MINUTE, create_date, CURRENT_TIMESTAMP)
FROM sys.databases WHERE name = 'tempdb';")"

    if [[ "$uptime_minutes" =~ ^[0-9]+$ ]] && (( uptime_minutes > 0 )); then
      echo "Uptime window cleared after ${attempt} check(s) (${uptime_minutes} minute(s) up)."
      return 0
    fi

    sleep 5
  done

  echo "::warning::Instance still reports under a minute of uptime; continuing anyway."
}

# ---------------------------------------------------------------------------
# Materialise one branch's copy of the kit into a directory
#
# A script that does not exist at the given revision is skipped -- that is a
# script the PR adds, which has no baseline to compare against.
# ---------------------------------------------------------------------------
materialise_kit() {
  local revision="$1" dest="$2" script

  mkdir -p "$dest/OptionalScripts"

  for script in "${KIT_SCRIPTS[@]}"; do
    if git -C "$REPO_ROOT" cat-file -e "$revision:$script" 2>/dev/null; then
      git -C "$REPO_ROOT" show "$revision:$script" > "$dest/$script"
    else
      echo "  (not present at $revision, skipping: $script)"
    fi
  done
}

install_kit() {
  local dir="$1" quiet="${2:-}" script

  for script in "${KIT_SCRIPTS[@]}"; do
    [[ -f "$dir/$script" ]] || continue
    [[ -n "$quiet" ]] || echo "  installing $script"
    if ! run_file "$dir/$script" > "$WORK_DIR/install.log" 2>&1; then
      echo "::error::Failed to install $script"
      cat "$WORK_DIR/install.log"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Reduce a step's output to a stable error signature.
#
# Comparing failure *labels* alone would turn every step that fails on base into
# a permanent allowlist entry: a PR could introduce a completely different error
# inside that step and stay green.
#
# The message text has to be part of the signature, not just the number. Msg
# 50000 is whatever RAISERROR was handed, and CommandExecute alone raises it for
# many unrelated validation failures -- keyed on the number only, a step could
# change from one Msg 50000 to a completely different one and still look
# unchanged.
#
# Stripped, because they move without the error changing: server name (random
# container hostname), Procedure/Line (shift whenever a PR edits the file above
# them), and any quoted literal (file paths and object names vary per run).
# ---------------------------------------------------------------------------
error_signature() {
  awk '
    /^Msg [0-9]+, Level [0-9]+, State [0-9]+/ {
      header = $0
      if ((getline detail) > 0) { print header " :: " detail } else { print header }
      next
    }
    /^Sqlcmd: Error/ { print }
  ' "$1" 2>/dev/null \
    | sed -E "s/, Server [^,]+,/,/; s/, Procedure [^,]+,/,/; s/, Line [0-9]+//" \
    | sed -E "s/'[^']*'/'X'/g" \
    | sort -u \
    | tr '\n' ';' \
    || true
}

# Run one step file. Sets STEP_SIGNATURE; returns non-zero if the step failed.
STEP_SIGNATURE=""
run_one_step() {
  local step_file="$1" log_file="$2"

  if "$SQLCMD" "${SQLCMD_ARGS[@]}" -d master -i "$step_file" > "$log_file" 2>&1; then
    STEP_SIGNATURE=""
    return 0
  fi

  STEP_SIGNATURE="$(error_signature "$log_file")"
  return 1
}

split_matrix() {
  local steps_dir="$1"

  rm -rf "$steps_dir"
  mkdir -p "$steps_dir"

  python3 - "$MATRIX_SQL" "$steps_dir" <<'PYTHON'
import os
import sys

matrix_path, steps_dir = sys.argv[1], sys.argv[2]

steps, label, buf = [], None, []
with open(matrix_path, encoding="utf-8") as handle:
    for line in handle:
        if line.startswith("--#STEP:"):
            if label is not None:
                steps.append((label, "".join(buf)))
            label = line.split(":", 1)[1].strip()
            buf = []
        elif label is not None:
            buf.append(line)
if label is not None:
    steps.append((label, "".join(buf)))

for index, (step_label, body) in enumerate(steps):
    with open(os.path.join(steps_dir, f"{index:03d}.sql"), "w", encoding="utf-8") as handle:
        handle.write(body)
    with open(os.path.join(steps_dir, f"{index:03d}.label"), "w", encoding="utf-8") as handle:
        handle.write(step_label)
PYTHON
}

# ---------------------------------------------------------------------------
# Run every step on its own, so one failure is attributed to one labelled step
# and the rest of the matrix still runs. One CI round should surface every
# problem, not just the first.
#
# Writes "<status><TAB><label><TAB><signature><TAB><step file>" per step.
# ---------------------------------------------------------------------------
run_matrix() {
  local pass_name="$1" results_file="$2"
  local steps_dir="$WORK_DIR/steps"
  local step_file current_label failures=0

  : > "$results_file"

  for step_file in "$steps_dir"/*.sql; do
    current_label="$(cat "${step_file%.sql}.label")"

    if run_one_step "$step_file" "$WORK_DIR/step.log"; then
      printf 'PASS\t%s\t\t%s\n' "$current_label" "$step_file" >> "$results_file"
      echo "  PASS  $current_label"
    else
      printf 'FAIL\t%s\t%s\t%s\n' "$current_label" "$STEP_SIGNATURE" "$step_file" >> "$results_file"
      echo "  FAIL  $current_label"
      # Surface the diagnostics themselves, not a blind tail: these procs print
      # result sets, so the error scrolls out of view long before the end.
      {
        grep -E -A2 '^(Msg [0-9]+,|Sqlcmd: Error)' "$WORK_DIR/step.log" | head -24 || true
        echo "--- last lines ---"
        tail -6 "$WORK_DIR/step.log"
      } | sed 's/^/        /'
      failures=$((failures + 1))
    fi
  done

  echo "  $pass_name: $failures failing step(s)"
}

# ---------------------------------------------------------------------------
# sp_Blitz findings, captured through the @Output* table path so that code path
# gets exercised too. Ordered so the two passes are directly comparable.
#
# Findings whose text embeds a timestamp or other per-run value are excluded --
# CheckID 156 puts GETDATE() straight into Finding, so leaving it in would report
# a removal and an addition on every single run and bury any real change.
# ---------------------------------------------------------------------------
VOLATILE_CHECK_IDS="156"

capture_findings() {
  local destination="$1"

  run_query "
SET NOCOUNT ON;
IF OBJECT_ID('FRKSmokeTest.dbo.BlitzFindings') IS NOT NULL
    DROP TABLE FRKSmokeTest.dbo.BlitzFindings;
" >/dev/null

  # Carries the same skip list as the matrix steps. Without it the CheckID 106
  # trace-file race (issue #4050) could abort this run instead, which would kill
  # the whole script rather than one labelled step.
  run_query "
EXEC dbo.sp_Blitz
     @CheckUserDatabaseObjects = 1,
     @CheckServerInfo          = 1,
     @OutputDatabaseName       = 'FRKSmokeTest',
     @OutputSchemaName         = 'dbo',
     @OutputTableName          = 'BlitzFindings',
     @SkipChecksDatabase       = 'FRKSmokeTest',
     @SkipChecksSchema         = 'dbo',
     @SkipChecksTable          = 'BlitzChecksToSkip';
" >/dev/null

  "$SQLCMD" "${SQLCMD_ARGS[@]}" -d FRKSmokeTest -h -1 -W -s '|' -Q "
SET NOCOUNT ON;
SELECT CONVERT(VARCHAR(10), CheckID)
       + '|' + ISNULL(DatabaseName, '(server)')
       + '|' + ISNULL(Finding, '')
FROM dbo.BlitzFindings
WHERE CheckID NOT IN ($VOLATILE_CHECK_IDS)
ORDER BY CheckID, DatabaseName, Finding;
" | sed '/^$/d;/rows affected/d' | sort -u > "$destination"
}

# ---------------------------------------------------------------------------
# Reset mutable state between passes so the two runs see the same server.
#
# Anything a matrix step can create has to be listed here, or the head pass
# skips the create path the base pass already took and the comparison quietly
# stops testing it. BlitzChecksToSkip is deliberately NOT dropped -- the seed
# creates it once and both passes need it.
# ---------------------------------------------------------------------------
reset_between_passes() {
  run_query "
SET NOCOUNT ON;

IF DB_ID('FRKSmokeTestRestored') IS NOT NULL
BEGIN
    ALTER DATABASE FRKSmokeTestRestored SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE FRKSmokeTestRestored;
END;

DECLARE @drop NVARCHAR(MAX) = N'';

SELECT @drop = @drop + N'DROP TABLE FRKSmokeTest.dbo.' + QUOTENAME(name) + N';'
FROM FRKSmokeTest.sys.tables
WHERE name IN (N'BlitzOutput', N'BlitzCache', N'BlitzFirst', N'BlitzFirst_FileStats',
               N'BlitzFirst_PerfmonStats', N'BlitzFirst_WaitStats',
               N'BlitzFirst_WaitStats_Categories', N'BlitzWho',
               N'BlitzWho_Results', N'BlitzLock', N'BlitzIndex', N'BlitzFindings');

IF @drop <> N'' EXEC sys.sp_executesql @drop;

/* sp_BlitzLock creates synonyms when logging to a table. */
DECLARE @dropsyn NVARCHAR(MAX) = N'';

SELECT @dropsyn = @dropsyn + N'DROP SYNONYM ' + QUOTENAME(name) + N';'
FROM sys.synonyms
WHERE name IN (N'DeadlockFindings', N'DeadLockTbl');

IF @dropsyn <> N'' EXEC sys.sp_executesql @dropsyn;
" >/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
wait_for_sql_server
wait_for_wait_stats

# sp_DatabaseRestore aborts unless Ola Hallengren's CommandExecute exists in the
# calling database, and CommandExecute in turn refuses @LogToTable = 'Y' unless
# dbo.CommandLog exists -- sp_DatabaseRestore always passes 'Y'. Both are needed
# or the restore path is untestable. The workflow downloads and checksums them;
# installing has to wait until the instance is up, so it happens here. CommandLog
# first: CommandExecute checks for it at runtime.
for dependency in "${COMMANDLOG_SQL:-}" "${COMMANDEXECUTE_SQL:-}"; do
  [[ -n "$dependency" ]] || continue
  if [[ ! -f "$dependency" ]]; then
    echo "::error::Expected dependency '$dependency' does not exist." >&2
    exit 1
  fi
  echo
  echo "=== Installing $(basename "$dependency") (sp_DatabaseRestore dependency) ==="
  run_file "$dependency"
done

echo
echo "=== Seeding test data ==="
run_file "$SEED_SQL"

split_matrix "$WORK_DIR/steps"

BASE_REVISION="${GITHUB_BASE_SHA:-}"
if [[ -z "$BASE_REVISION" && -n "${GITHUB_BASE_REF:-}" ]]; then
  BASE_REVISION="origin/${GITHUB_BASE_REF}"
fi

base_ran=0
if [[ -n "$BASE_REVISION" ]] && git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_REVISION" >/dev/null; then
  echo
  echo "=== Pass 1: base ($BASE_REVISION) ==="
  materialise_kit "$BASE_REVISION" "$WORK_DIR/base"
  install_kit "$WORK_DIR/base"
  run_matrix "base" "$WORK_DIR/base-results.txt"
  capture_findings "$WORK_DIR/base-findings.txt"
  reset_between_passes
  base_ran=1
else
  echo
  echo "No usable base revision (GITHUB_BASE_SHA/GITHUB_BASE_REF); skipping the"
  echo "comparison pass and checking this branch for errors only."
  : > "$WORK_DIR/base-results.txt"
  : > "$WORK_DIR/base-findings.txt"
fi

echo
echo "=== Pass 2: this branch ==="
install_kit "$REPO_ROOT"
run_matrix "head" "$WORK_DIR/head-results.txt"
capture_findings "$WORK_DIR/head-findings.txt"

# ---------------------------------------------------------------------------
# Report: findings differences are informational
# ---------------------------------------------------------------------------
echo
echo "=== sp_Blitz findings: base vs this branch ==="
if [[ "$base_ran" -eq 1 ]]; then
  added="$(comm -13 "$WORK_DIR/base-findings.txt" "$WORK_DIR/head-findings.txt" || true)"
  removed="$(comm -23 "$WORK_DIR/base-findings.txt" "$WORK_DIR/head-findings.txt" || true)"

  if [[ -z "$added" && -z "$removed" ]]; then
    echo "No change. $(wc -l < "$WORK_DIR/head-findings.txt" | tr -d ' ') findings, identical to base."
  else
    echo "This branch changes what sp_Blitz reports. Not a failure -- review it."
    if [[ -n "$removed" ]]; then
      echo
      echo "  No longer reported:"
      sed 's/^/    - /' <<< "$removed"
    fi
    if [[ -n "$added" ]]; then
      echo
      echo "  Newly reported:"
      sed 's/^/    + /' <<< "$added"
    fi
    {
      echo "### sp_Blitz findings changed on \`${MSSQL_IMAGE:-this image}\`"
      echo
      echo "Informational -- review whether these are intended."
      [[ -n "$removed" ]] && { echo; echo "**No longer reported:**"; echo '```'; echo "$removed"; echo '```'; }
      [[ -n "$added" ]] && { echo; echo "**Newly reported:**"; echo '```'; echo "$added"; echo '```'; }
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fi
else
  echo "Skipped (no base pass)."
fi

# ---------------------------------------------------------------------------
# Report: errors decide the build
#
# A head failure counts as pre-existing only when the same step failed on base
# with the same diagnostics.
#
# A first-attempt mismatch is not enough to blame the PR. The two passes run
# minutes apart against one server whose state keeps moving, and transient
# errors -- a torn default-trace read, a plan aged out mid-step -- land on
# whichever pass is unlucky. That produced a red build on a PR that changed no
# stored procedure at all. So every mismatch is re-confirmed before it counts:
# retry on head, and if it still fails, put base's copies back and run it there
# too. Only a failure that survives both is attributed to this branch.
# ---------------------------------------------------------------------------
echo
echo "=== Errors ==="

mismatches=""
pre_existing=""

while IFS=$'\t' read -r status step_label head_signature step_file; do
  [[ "$status" == "FAIL" ]] || continue

  base_signature="$(awk -F'\t' -v want="$step_label" \
    '$1 == "FAIL" && $2 == want { print $3; exit }' "$WORK_DIR/base-results.txt")"

  if [[ -n "$base_signature" && "$base_signature" == "$head_signature" ]]; then
    pre_existing+="$step_label -- $head_signature"$'\n'
  else
    mismatches+="$step_label"$'\t'"$head_signature"$'\t'"$step_file"$'\t'"$base_signature"$'\n'
  fi
done < "$WORK_DIR/head-results.txt"

mismatches="$(sed '/^$/d' <<< "$mismatches")"
new_failures=""

if [[ -n "$mismatches" ]]; then
  echo "Re-confirming $(wc -l <<< "$mismatches" | tr -d ' ') mismatch(es) before attributing them to this branch..."

  # Round 1: does it still fail on head?
  still_failing=""
  while IFS=$'\t' read -r step_label head_signature step_file base_signature; do
    [[ -n "$step_label" ]] || continue
    if run_one_step "$step_file" "$WORK_DIR/recheck.log"; then
      echo "  transient: '$step_label' passed on retry against this branch -- not a regression"
    else
      still_failing+="$step_label"$'\t'"$STEP_SIGNATURE"$'\t'"$step_file"$'\t'"$base_signature"$'\n'
    fi
  done <<< "$mismatches"

  still_failing="$(sed '/^$/d' <<< "$still_failing")"

  # Round 2: reinstall base and see whether it fails there too, now.
  if [[ -n "$still_failing" && "$base_ran" -eq 1 ]]; then
    echo "  reinstalling base to re-test $(wc -l <<< "$still_failing" | tr -d ' ') step(s) against it..."
    install_kit "$WORK_DIR/base" quiet

    while IFS=$'\t' read -r step_label head_signature step_file base_signature; do
      [[ -n "$step_label" ]] || continue
      if run_one_step "$step_file" "$WORK_DIR/recheck-base.log"; then
        new_failures+="$step_label -- $head_signature"$'\n'
      elif [[ "$STEP_SIGNATURE" == "$head_signature" ]]; then
        echo "  environmental: '$step_label' fails the same way on base when re-run -- not a regression"
        pre_existing+="$step_label -- $head_signature (confirmed on re-run)"$'\n'
      else
        new_failures+="$step_label -- error changed: base [$STEP_SIGNATURE] head [$head_signature]"$'\n'
      fi
    done <<< "$still_failing"

    install_kit "$REPO_ROOT" quiet
  elif [[ -n "$still_failing" ]]; then
    while IFS=$'\t' read -r step_label head_signature _ _; do
      [[ -n "$step_label" ]] || continue
      new_failures+="$step_label -- $head_signature"$'\n'
    done <<< "$still_failing"
  fi
fi

pre_existing="$(sed '/^$/d' <<< "$pre_existing")"
new_failures="$(sed '/^$/d' <<< "$new_failures")"

if [[ -n "$pre_existing" ]]; then
  echo
  echo "Already failing on base with the same error -- not caused by this branch:"
  sed 's/^/  ~ /' <<< "$pre_existing"
fi

if [[ -n "$new_failures" ]]; then
  echo
  echo "::error::This branch introduces SQL errors in $(wc -l <<< "$new_failures" | tr -d ' ') step(s)."
  sed 's/^/  ! /' <<< "$new_failures"
  {
    echo "### New SQL errors on \`${MSSQL_IMAGE:-this image}\`"
    echo
    echo "Each was re-run against this branch and against base before being reported."
    echo '```'
    echo "$new_failures"
    echo '```'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
fi

echo "No new SQL errors."
echo
echo "Smoke tests passed."
