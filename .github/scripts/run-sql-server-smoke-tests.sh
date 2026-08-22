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
MATRIX_REL_PATH=".github/scripts/smoke-test-matrix.sql"

# Everything that shapes how a step runs. If the PR touches any of it, no
# failure may be grandfathered: both passes use THIS branch's harness, so a
# change that breaks it -- dropping -I, say -- breaks unchanged steps against
# base and head alike and would otherwise be waved through as pre-existing.
HARNESS_FILES=(
  ".github/scripts/run-sql-server-smoke-tests.sh"
  ".github/scripts/smoke-test-seed.sql"
  ".github/scripts/smoke-test-matrix.sql"
  ".github/workflows/sql-server-smoke-tests.yml"
)
harness_unchanged=0

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
    # `|| true` matters: under set -e a failed command substitution aborts the
    # script, which would contradict the contract above that an error means
    # "not yet confirmed, keep waiting".
    uptime_minutes="$(run_scalar "SET NOCOUNT ON;
SELECT DATEDIFF(MINUTE, create_date, CURRENT_TIMESTAMP)
FROM sys.databases WHERE name = 'tempdb';" || true)"

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

kit_proc_name() {
  basename "$1" .sql
}

# Each pass starts from absent kit objects.
#
# Otherwise the previous pass's procedures survive: a script deleted on head is
# silently skipped by the install loop, and a script reduced to an empty file
# still makes sqlcmd exit 0. Either way the head matrix would run the stale base
# procedure and pass without ever touching the head artifact.
drop_kit_objects() {
  local script proc statements=""

  for script in "${KIT_SCRIPTS[@]}"; do
    proc="$(kit_proc_name "$script")"
    statements+="IF OBJECT_ID('dbo.$proc', 'P') IS NOT NULL DROP PROCEDURE dbo.$proc;"
  done

  run_query "SET NOCOUNT ON; $statements" >/dev/null
}

# Installing without error is not proof the procedure exists.
verify_kit_installed() {
  local dir="$1" script proc missing=""

  for script in "${KIT_SCRIPTS[@]}"; do
    [[ -f "$dir/$script" ]] || continue
    proc="$(kit_proc_name "$script")"
    if [[ "$(run_scalar "SET NOCOUNT ON;
SELECT CASE WHEN OBJECT_ID('dbo.$proc', 'P') IS NULL THEN 'MISSING' ELSE 'OK' END;" || true)" != "OK" ]]; then
      missing+="$proc "
    fi
  done

  if [[ -n "$missing" ]]; then
    echo "::error::Installed without error but these procedures do not exist: $missing"
    return 1
  fi
}

install_kit() {
  local dir="$1" quiet="${2:-}" script

  drop_kit_objects

  for script in "${KIT_SCRIPTS[@]}"; do
    [[ -f "$dir/$script" ]] || continue
    [[ -n "$quiet" ]] || echo "  installing $script"
    if ! run_file "$dir/$script" > "$WORK_DIR/install.log" 2>&1; then
      echo "::error::Failed to install $script"
      cat "$WORK_DIR/install.log"
      return 1
    fi
  done

  verify_kit_installed "$dir"
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
# container hostname) and Procedure/Line (shift whenever a PR edits the file
# above them).
#
# Quoted literals are NOT stripped wholesale. A quoted name is often the only
# thing separating two errors -- Msg 208 for 'OldTable' and for 'NewTable' are
# different bugs -- so blanking them all would let a real regression inherit a
# grandfathered signature. Only quoted values containing a path separator are
# normalised, which covers the volatile ones (rotating trace files, per-run
# backup paths) and leaves deterministic identifiers intact.
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
    | sed -E "s@'[^']*[/\\\\][^']*'@'PATH'@g" \
    | sort -u \
    | tr '\n' ';' \
    || true
}

# ---------------------------------------------------------------------------
# Is this step byte-identical to the one base runs under the same label?
#
# Both passes execute THIS branch's matrix, so a step the PR adds or edits runs
# against base's procedures too. A defect in the step itself -- a typo'd
# procedure name, a bad parameter -- therefore fails identically on both passes
# and would be waved through as "pre-existing". Only a step base also has, with
# the same body, may be grandfathered; anything new or edited has to pass on its
# own merits.
# ---------------------------------------------------------------------------
# Sets harness_unchanged. Any difference, or any file absent from base, means no.
check_harness_unchanged() {
  local revision="$1" file

  for file in "${HARNESS_FILES[@]}"; do
    if ! git -C "$REPO_ROOT" cat-file -e "$revision:$file" 2>/dev/null; then
      echo "  harness file is new on this branch: $file"
      harness_unchanged=0
      return
    fi
    if ! git -C "$REPO_ROOT" show "$revision:$file" | cmp -s - "$REPO_ROOT/$file"; then
      echo "  harness file changed on this branch: $file"
      harness_unchanged=0
      return
    fi
  done

  harness_unchanged=1
}

step_unchanged_from_base() {
  local label="$1" head_file="$2" base_label_file

  [[ -d "$WORK_DIR/base-steps" ]] || return 1

  for base_label_file in "$WORK_DIR/base-steps"/*.label; do
    [[ -e "$base_label_file" ]] || return 1
    if [[ "$(cat "$base_label_file")" == "$label" ]]; then
      cmp -s "${base_label_file%.label}.sql" "$head_file" && return 0
      return 1
    fi
  done

  return 1
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
  local matrix_file="${2:-$MATRIX_SQL}"

  rm -rf "$steps_dir"
  mkdir -p "$steps_dir"

  python3 - "$matrix_file" "$steps_dir" <<'PYTHON'
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

# Returns non-zero, without aborting the job, when sp_Blitz cannot produce a
# findings set. This runs the same full configuration the matrix just exercised,
# so if sp_Blitz is failing -- including failing on base, before this branch is
# involved at all -- this call fails too. Under `sqlcmd -b` and `set -e` that
# would kill the run here, before the head pass, and the comparison logic that
# exists to classify exactly that failure would never be reached. The findings
# diff is informational, so losing it is survivable; losing the error
# classification is not.
capture_findings() {
  local destination="$1"

  : > "$destination"

  run_query "
SET NOCOUNT ON;
IF OBJECT_ID('FRKSmokeTest.dbo.BlitzFindings') IS NOT NULL
    DROP TABLE FRKSmokeTest.dbo.BlitzFindings;
" >/dev/null 2>&1 || true

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
" >/dev/null 2>&1 || {
    echo "  ::warning::sp_Blitz failed while capturing findings; the findings comparison will be skipped."
    return 1
  }

  # -y 0 and -w 65535 matter: this output is parsed, not read. sqlcmd defaults to
  # an 80-character screen width and truncates variable-length columns at 256,
  # while a row here reaches ~340 (CheckID + NVARCHAR(128) DatabaseName +
  # VARCHAR(200) Finding). Wrapped or clipped rows would make sort/comm compare
  # fragments and quietly miss real differences.
  "$SQLCMD" "${SQLCMD_ARGS[@]}" -d FRKSmokeTest -h -1 -W -y 0 -w 65535 -s '|' -Q "
SET NOCOUNT ON;
SELECT CONVERT(VARCHAR(10), CheckID)
       + '|' + ISNULL(DatabaseName, '(server)')
       + '|' + ISNULL(Finding, '')
FROM dbo.BlitzFindings
WHERE CheckID NOT IN ($VOLATILE_CHECK_IDS)
ORDER BY CheckID, DatabaseName, Finding;
" 2>/dev/null | sed '/^$/d;/rows affected/d' | sort -u > "$destination" || return 1
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

/* sp_BlitzFirst's logging path also creates views alongside each table:
   <FileStats>_Deltas, <PerfmonStats>_Deltas, <PerfmonStats>_Actuals and
   <WaitStats>_Deltas. Dropping only the tables would leave the base pass's
   views in place, so the head pass would skip all four view-creation paths. */
DECLARE @dropview NVARCHAR(MAX) = N'';

/* DROP VIEW rejects a three-part name -- 'DROP VIEW' does not allow specifying
   the database name as a prefix (Msg 166), unlike DROP TABLE, which accepts one.
   So the statement is built with two-part names and executed inside the target
   database via its own sp_executesql. */
SELECT @dropview = @dropview + N'DROP VIEW dbo.' + QUOTENAME(name) + N';'
FROM FRKSmokeTest.sys.views
WHERE name IN (N'BlitzFirst_FileStats_Deltas', N'BlitzFirst_PerfmonStats_Deltas',
               N'BlitzFirst_PerfmonStats_Actuals', N'BlitzFirst_WaitStats_Deltas',
               /* sp_BlitzWho makes <table>_Deltas for whatever table it logs to,
                  once via sp_BlitzFirst's @OutputTableNameBlitzWho and once from
                  the direct sp_BlitzWho step. */
               N'BlitzWho_Deltas', N'BlitzWho_Results_Deltas')
  AND SCHEMA_NAME(schema_id) = N'dbo';

IF @dropview <> N'' EXEC FRKSmokeTest.sys.sp_executesql @dropview;
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

# sp_DatabaseRestore's dependencies (Ola Hallengren's CommandLog and
# CommandExecute) are deliberately NOT installed: the only invocation left is
# @Help = 1, which returns at sp_DatabaseRestore.sql:71, long before the
# CommandExecute check at :255. Fetching them would add two network downloads
# and two checksums that can redden every PR while exercising nothing. Restore
# them alongside the execute-path step when #4049 lands.

echo
echo "=== Seeding test data ==="
run_file "$SEED_SQL"

split_matrix "$WORK_DIR/steps"

BASE_REVISION="${GITHUB_BASE_SHA:-}"
if [[ -z "$BASE_REVISION" && -n "${GITHUB_BASE_REF:-}" ]]; then
  BASE_REVISION="origin/${GITHUB_BASE_REF}"
fi

base_ran=0
base_findings_ok=0
head_findings_ok=0
if [[ -n "$BASE_REVISION" ]] && git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_REVISION" >/dev/null; then
  echo
  echo "=== Pass 1: base ($BASE_REVISION) ==="

  check_harness_unchanged "$BASE_REVISION"
  if [[ "$harness_unchanged" -eq 1 ]]; then
    echo "  harness unchanged from base; unchanged steps may be grandfathered"
  else
    echo "  harness differs from base; every step must pass on its own merits"
  fi

  # Base's own copy of the matrix, so we can tell which steps this PR added or
  # edited. Those must pass on their own merits -- see step_unchanged_from_base.
  if git -C "$REPO_ROOT" cat-file -e "$BASE_REVISION:$MATRIX_REL_PATH" 2>/dev/null; then
    git -C "$REPO_ROOT" show "$BASE_REVISION:$MATRIX_REL_PATH" > "$WORK_DIR/base-matrix.sql"
    split_matrix "$WORK_DIR/base-steps" "$WORK_DIR/base-matrix.sql"
    echo "  base matrix: $(find "$WORK_DIR/base-steps" -name '*.sql' | wc -l | tr -d ' ') step(s) to compare against"
  else
    echo "  base has no matrix file; every step counts as new and must pass on its own"
  fi

  materialise_kit "$BASE_REVISION" "$WORK_DIR/base"
  install_kit "$WORK_DIR/base"
  run_matrix "base" "$WORK_DIR/base-results.txt"
  base_findings_ok=1
  capture_findings "$WORK_DIR/base-findings.txt" || base_findings_ok=0
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
head_findings_ok=1
capture_findings "$WORK_DIR/head-findings.txt" || head_findings_ok=0

# ---------------------------------------------------------------------------
# Report: findings differences are informational
# ---------------------------------------------------------------------------
echo
echo "=== sp_Blitz findings: base vs this branch ==="
if [[ "$base_ran" -eq 1 && "$base_findings_ok" -eq 1 && "$head_findings_ok" -eq 1 ]]; then
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
elif [[ "$base_ran" -ne 1 ]]; then
  echo "Skipped (no base pass)."
else
  if [[ "$base_findings_ok" -ne 1 && "$head_findings_ok" -ne 1 ]]; then
    echo "Skipped: sp_Blitz could not produce a findings set on either revision."
  elif [[ "$base_findings_ok" -ne 1 ]]; then
    echo "Skipped: sp_Blitz could not produce a findings set on base."
  else
    echo "Skipped: sp_Blitz could not produce a findings set on this branch."
  fi
  echo "The error classification below is unaffected."
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

# Look up one label's outcome in a results file: "<status><TAB><signature>".
lookup_result() {
  awk -F'\t' -v want="$2" '$2 == want { print $1 "\t" $3; exit }' "$1"
}

while IFS=$'\t' read -r status step_label head_signature step_file; do
  [[ "$status" == "FAIL" ]] || continue

  base_signature="$(awk -F'\t' -v want="$step_label" \
    '$1 == "FAIL" && $2 == want { print $3; exit }' "$WORK_DIR/base-results.txt")"

  if [[ -n "$base_signature" && "$base_signature" == "$head_signature" ]] \
     && [[ "$harness_unchanged" -eq 1 ]] \
     && step_unchanged_from_base "$step_label" "$step_file"; then
    pre_existing+="$step_label -- $head_signature"$'\n'
  else
    mismatches+="$step_label"$'\t'"$head_signature"$'\t'"$step_file"$'\t'"$base_signature"$'\n'
  fi
done < "$WORK_DIR/head-results.txt"

mismatches="$(sed '/^$/d' <<< "$mismatches")"
new_failures=""

if [[ -n "$mismatches" ]]; then
  echo "Re-confirming $(wc -l <<< "$mismatches" | tr -d ' ') mismatch(es) before attributing them to this branch."
  echo "Re-running the whole matrix rather than the failing steps alone: several steps"
  echo "create persistent objects, so replaying one in place would let it skip the very"
  echo "create branch that failed and look transient."

  # Round 1: the full matrix again on head, from the same reset state the
  # original pass started from.
  reset_between_passes
  install_kit "$REPO_ROOT" quiet
  run_matrix "head re-check" "$WORK_DIR/head-recheck.txt"

  still_failing=""
  while IFS=$'\t' read -r step_label head_signature step_file base_signature; do
    [[ -n "$step_label" ]] || continue
    IFS=$'\t' read -r recheck_status recheck_signature < <(lookup_result "$WORK_DIR/head-recheck.txt" "$step_label")
    if [[ "$recheck_status" == "PASS" ]]; then
      echo "  transient: '$step_label' passed when the matrix was replayed -- not a regression"
    else
      still_failing+="$step_label"$'\t'"$recheck_signature"$'\t'"$step_file"$'\t'"$base_signature"$'\n'
    fi
  done <<< "$mismatches"

  still_failing="$(sed '/^$/d' <<< "$still_failing")"

  # Round 2: the full matrix against base, same way.
  if [[ -n "$still_failing" && "$base_ran" -eq 1 ]]; then
    echo "  replaying the matrix against base for $(wc -l <<< "$still_failing" | tr -d ' ') step(s)..."
    reset_between_passes
    install_kit "$WORK_DIR/base" quiet
    run_matrix "base re-check" "$WORK_DIR/base-recheck.txt"

    while IFS=$'\t' read -r step_label head_signature step_file base_signature; do
      [[ -n "$step_label" ]] || continue
      IFS=$'\t' read -r rebase_status rebase_signature < <(lookup_result "$WORK_DIR/base-recheck.txt" "$step_label")

      if [[ "$rebase_status" == "PASS" ]]; then
        new_failures+="$step_label -- $head_signature"$'\n'
      elif [[ "$rebase_signature" == "$head_signature" ]] \
           && [[ "$harness_unchanged" -eq 1 ]] \
           && step_unchanged_from_base "$step_label" "$step_file"; then
        echo "  environmental: '$step_label' fails the same way on base when replayed -- not a regression"
        pre_existing+="$step_label -- $head_signature (confirmed on replay)"$'\n'
      else
        new_failures+="$step_label -- error changed: base [$rebase_signature] head [$head_signature]"$'\n'
      fi
    done <<< "$still_failing"

    # Leave this branch's procedures installed, so the job ends as it began.
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
