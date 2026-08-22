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
#   * A SQL error that the base branch does not also produce FAILS the build.
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

SQLCMD_ARGS=(
  -S "$SQLCMDSERVER"
  -U "$SQLCMDUSER"
  -P "$SQLCMDPASSWORD"
  -C
  -b
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
  local dir="$1" script

  for script in "${KIT_SCRIPTS[@]}"; do
    [[ -f "$dir/$script" ]] || continue
    echo "  installing $script"
    if ! run_file "$dir/$script" > "$WORK_DIR/install.log" 2>&1; then
      echo "::error::Failed to install $script"
      cat "$WORK_DIR/install.log"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Split the matrix on --#STEP: markers and run each step on its own.
#
# Each step runs separately so one failure is attributed to one labelled step
# and the rest of the matrix still runs -- we want every problem in a single CI
# round, not just the first.
#
# Writes one "<status>\t<label>" line per step to the named results file.
# ---------------------------------------------------------------------------
run_matrix() {
  local label="$1" results_file="$2"
  local steps_dir="$WORK_DIR/steps-$label"
  local step_file current_label failures=0

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

  : > "$results_file"

  for step_file in "$steps_dir"/*.sql; do
    current_label="$(cat "${step_file%.sql}.label")"

    if "$SQLCMD" "${SQLCMD_ARGS[@]}" -d master -i "$step_file" \
         > "$WORK_DIR/step.log" 2>&1; then
      printf 'PASS\t%s\n' "$current_label" >> "$results_file"
      echo "  PASS  $current_label"
    else
      printf 'FAIL\t%s\n' "$current_label" >> "$results_file"
      echo "  FAIL  $current_label"
      # Keep the error text; it is what a reviewer needs to see.
      sed 's/^/        /' "$WORK_DIR/step.log" | tail -25
      failures=$((failures + 1))
    fi
  done

  echo "  $label: $failures failing step(s)"
}

# ---------------------------------------------------------------------------
# sp_Blitz findings, captured through the @Output* table path so that code path
# gets exercised too. Ordered so the two passes are directly comparable.
# ---------------------------------------------------------------------------
capture_findings() {
  local destination="$1"

  run_query "
SET NOCOUNT ON;
IF OBJECT_ID('FRKSmokeTest.dbo.BlitzFindings') IS NOT NULL
    DROP TABLE FRKSmokeTest.dbo.BlitzFindings;
" >/dev/null

  run_query "
EXEC dbo.sp_Blitz
     @CheckUserDatabaseObjects = 1,
     @CheckServerInfo          = 1,
     @OutputDatabaseName       = 'FRKSmokeTest',
     @OutputSchemaName         = 'dbo',
     @OutputTableName          = 'BlitzFindings';
" >/dev/null

  "$SQLCMD" "${SQLCMD_ARGS[@]}" -d FRKSmokeTest -h -1 -W -s '|' -Q "
SET NOCOUNT ON;
SELECT CONVERT(VARCHAR(10), CheckID)
       + '|' + ISNULL(DatabaseName, '(server)')
       + '|' + ISNULL(Finding, '')
FROM dbo.BlitzFindings
ORDER BY CheckID, DatabaseName, Finding;
" | sed '/^$/d;/rows affected/d' | sort -u > "$destination"
}

# ---------------------------------------------------------------------------
# Reset mutable state between passes so the two runs see the same server.
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
               N'BlitzFirst_PerfmonStats', N'BlitzFirst_WaitStats', N'BlitzWho',
               N'BlitzWho_Results', N'BlitzLock', N'BlitzIndex', N'BlitzFindings');

IF @drop <> N'' EXEC sys.sp_executesql @drop;
" >/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
wait_for_sql_server

echo
echo "=== Seeding test data ==="
run_file "$SEED_SQL"

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
# ---------------------------------------------------------------------------
echo
echo "=== Errors ==="

head_failures="$(awk -F'\t' '$1 == "FAIL" { print $2 }' "$WORK_DIR/head-results.txt" || true)"
base_failures="$(awk -F'\t' '$1 == "FAIL" { print $2 }' "$WORK_DIR/base-results.txt" || true)"

new_failures=""
while IFS= read -r failing_step; do
  [[ -n "$failing_step" ]] || continue
  if ! grep -Fxq "$failing_step" <<< "$base_failures"; then
    new_failures+="$failing_step"$'\n'
  fi
done <<< "$head_failures"

pre_existing="$(comm -12 <(sort <<< "$head_failures") <(sort <<< "$base_failures") | sed '/^$/d' || true)"

if [[ -n "$pre_existing" ]]; then
  echo "Already failing on base -- not caused by this branch:"
  sed 's/^/  ~ /' <<< "$pre_existing"
fi

new_failures="$(sed '/^$/d' <<< "$new_failures")"
if [[ -n "$new_failures" ]]; then
  echo
  echo "::error::This branch introduces SQL errors in $(wc -l <<< "$new_failures" | tr -d ' ') step(s)."
  sed 's/^/  ! /' <<< "$new_failures"
  {
    echo "### New SQL errors on \`${MSSQL_IMAGE:-this image}\`"
    echo
    echo '```'
    echo "$new_failures"
    echo '```'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
fi

echo "No new SQL errors."
echo
echo "Smoke tests passed."
