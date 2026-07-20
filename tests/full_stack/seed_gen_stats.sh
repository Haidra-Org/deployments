#!/usr/bin/env bash

# Gen-stats seeder for the load-test rig.
#
# Bulk-loads plausible rows into image_gen_stats and text_gen_stats so the
# AI-Horde stats-compile pg_cron jobs (compile_imagegen_stats_totals et al.)
# have real volume to scan. Those procedures run unbounded COUNT/SUM aggregate
# scans over the full tables every minute; their production cost comes from
# table size, which an empty local DB never reproduces. This is substrate, not
# scenario: it shapes the background DB load the rig exists to exercise.
#
# Rows are generated server-side via generate_series (no client round-trips per
# row) in batches, with timestamps spread over the last ~180 days and value
# distributions loosely resembling real traffic. Run AFTER `local_deploy.sh up
# --loadtest`.
#
# Usage:
#   ./tests/full_stack/seed_gen_stats.sh [--images N] [--text N] [--batch B]
#                                        [--container NAME] [--db DB] [--user USER]
# Defaults: --images 5000000 --text 2000000 --batch 500000
# Risk category: operational
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
if [ -f "$SCRIPT_DIR/../lib.sh" ]; then
  source "$SCRIPT_DIR/../lib.sh"
else
  log() { echo "[seed] $*"; }
  err() { echo "[seed][err] $*" >&2; }
fi

IMAGES=5000000
TEXT=2000000
BATCH=500000
CONTAINER="aihorde-postgres"
DB="aihorde"
USER="aihorde"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --images) shift; IMAGES="$1" ;;
    --images=*) IMAGES="${1#--images=}" ;;
    --text) shift; TEXT="$1" ;;
    --text=*) TEXT="${1#--text=}" ;;
    --batch) shift; BATCH="$1" ;;
    --batch=*) BATCH="${1#--batch=}" ;;
    --container) shift; CONTAINER="$1" ;;
    --container=*) CONTAINER="${1#--container=}" ;;
    --db) shift; DB="$1" ;;
    --db=*) DB="${1#--db=}" ;;
    --user) shift; USER="$1" ;;
    --user=*) USER="${1#--user=}" ;;
    -h|--help)
      echo "Usage: $0 [--images N] [--text N] [--batch B] [--container NAME] [--db DB] [--user USER]"
      exit 0
      ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  err "Postgres container '$CONTAINER' not found. Bring the rig up first: local_deploy.sh up --loadtest"
  exit 1
fi

# psql inside the container connects over the local socket (trust) as the
# rig user; no password needed. -q keeps batch output quiet.
psql_exec() {
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -q -U "$USER" -d "$DB" "$@"
}

# seed_table TABLE TOTAL BATCH SELECT_TEMPLATE
# The SELECT_TEMPLATE must reference :batch for the per-batch row count.
seed_batches() {
  local table="$1" total="$2" sql_fn="$3"
  local done=0 this
  log "Seeding $table: target ${total} rows (batch ${BATCH}) ..."
  while [ "$done" -lt "$total" ]; do
    this=$(( total - done ))
    [ "$this" -gt "$BATCH" ] && this="$BATCH"
    printf 'SET synchronous_commit=off;\n%s' "$("$sql_fn" "$this")" | psql_exec >/dev/null
    done=$(( done + this ))
    log "  $table: ${done}/${total}"
  done
}

image_sql() {
  local n="$1"
  cat <<SQL
INSERT INTO image_gen_stats
  (finished, created, model, width, height, steps, cfg, sampler, prompt_length,
   negprompt, img2img, hires_fix, tiling, nsfw, state, client_agent, bridge_agent)
SELECT
  ts, ts,
  (ARRAY['stable_diffusion','stable_diffusion_2.1','stable_diffusion_xl','flux.1','pony_diffusion_xl'])[1 + floor(random()*5)],
  (ARRAY[512,640,768,1024])[1 + floor(random()*4)],
  (ARRAY[512,640,768,1024])[1 + floor(random()*4)],
  (10 + floor(random()*40))::int,
  (1 + floor(random()*14))::int,
  (ARRAY['k_euler','k_euler_a','k_dpmpp_2m','k_dpmpp_sde','ddim'])[1 + floor(random()*5)],
  (10 + floor(random()*490))::int,
  random() < 0.30, random() < 0.20, random() < 0.15, random() < 0.05, random() < 0.10,
  'OK', 'unknown:0:unknown', 'unknown:0:unknown'
FROM (
  SELECT (now() at time zone 'utc') - (random() * interval '180 days') AS ts
  FROM generate_series(1, ${n})
) s;
SQL
}

text_sql() {
  local n="$1"
  cat <<SQL
INSERT INTO text_gen_stats
  (finished, created, model, max_length, max_context_length, softprompt,
   prompt_length, client_agent, bridge_agent, state)
SELECT
  ts, ts,
  (ARRAY['koboldcpp/LLaMA2-13B','koboldcpp/Mythomax-L2-13B','aphrodite/Mistral-7B','koboldcpp/Nous-Hermes','aphrodite/Mixtral-8x7B'])[1 + floor(random()*5)],
  (16 + floor(random()*496))::int,
  (512 + floor(random()*7680))::int,
  NULL,
  (10 + floor(random()*2000))::int,
  'unknown:0:unknown', 'unknown:0:unknown', 'OK'
FROM (
  SELECT (now() at time zone 'utc') - (random() * interval '180 days') AS ts
  FROM generate_series(1, ${n})
) s;
SQL
}

log "Seeding gen-stats into container=${CONTAINER} db=${DB} (images=${IMAGES} text=${TEXT})"

if [ "$IMAGES" -gt 0 ]; then
  seed_batches image_gen_stats "$IMAGES" image_sql
fi
if [ "$TEXT" -gt 0 ]; then
  seed_batches text_gen_stats "$TEXT" text_sql
fi

log "Refreshing planner statistics (ANALYZE) ..."
psql_exec -c "ANALYZE image_gen_stats;" >/dev/null
psql_exec -c "ANALYZE text_gen_stats;" >/dev/null

log "Row counts after seeding:"
psql_exec -c "SELECT 'image_gen_stats' AS table, count(*) FROM image_gen_stats
              UNION ALL SELECT 'text_gen_stats', count(*) FROM text_gen_stats;"

log "Done. The stats-compile pg_cron jobs will now scan populated tables."
