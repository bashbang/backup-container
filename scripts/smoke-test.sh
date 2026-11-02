#!/usr/bin/env bash
# Smoke test for the local backup workflow.
#
# This script validates the end-to-end backup path used by the project:
#   1. ensure a source database exists
#   2. load Sakila sample data if it is missing
#   3. create a backup archive
#   4. restore the newest backup into a second database
#   5. compare each restored table against the source data
#
# The comparison is intentionally done against the actual table rows, exported as
# a stable snapshot, rather than comparing raw dump output that can contain
# engine-specific metadata differences even when the data is identical.
#
# Usage:
#   bash scripts/smoke-test.sh
#   DB_TYPE=mysql bash scripts/smoke-test.sh
#
# Environment overrides:
#   COMPOSE_CMD     default: docker compose
#   RETRY_COUNT     default: 30
#   SLEEP_SECONDS   default: 2
#   DB_TYPE         default: postgres
#   DB_TYPES        default: postgres,mysql
#   SAKILA_DB_COMMIT default: pinned upstream Sakila commit
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
RETRY_COUNT="${RETRY_COUNT:-30}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"
if [[ -n "${DB_TYPE:-}" ]]; then
  DB_TYPE="${DB_TYPE}"
  DB_TYPES="${DB_TYPES:-${DB_TYPE}}"
else
  DB_TYPE="postgres"
  DB_TYPES="${DB_TYPES:-postgres,mysql}"
fi
DB_NAME="sakila"
RESTORE_DB_NAME="sakila_restore"

DB_SERVICE_NAME_OVERRIDE="${DB_SERVICE_NAME:-}"
BACKUP_SERVICE_NAME_OVERRIDE="${BACKUP_SERVICE_NAME:-}"
DB_PORT_OVERRIDE="${DB_PORT:-}"
DB_USER_OVERRIDE="${DB_USER:-}"

apply_backend_settings() {
  if [[ "${DB_TYPE}" == "mysql" ]]; then
    DB_SERVICE_NAME="${DB_SERVICE_NAME_OVERRIDE:-mysql}"
    BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME_OVERRIDE:-backup}"
    DB_PORT="${DB_PORT_OVERRIDE:-3306}"
    DB_USER="${DB_USER_OVERRIDE:-mysql}"
  else
    DB_SERVICE_NAME="${DB_SERVICE_NAME_OVERRIDE:-postgresql}"
    BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME_OVERRIDE:-backup}"
    DB_PORT="${DB_PORT_OVERRIDE:-5432}"
    DB_USER="${DB_USER_OVERRIDE:-postgres}"
  fi
}
apply_backend_settings
DB_PASSWORD="${DB_PASSWORD:-secret}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-secret}"

# Pin the Sakila scripts to a known-good upstream commit so the smoke test stays
# deterministic while still allowing a single-variable update when a new version
# is qualified.
SAKILA_DB_COMMIT="${SAKILA_DB_COMMIT:-e089a5b1ec9af0df7a9c6a5d47d49fa1736a4e84}"
SAKILA_DB_BASE_URL="https://raw.githubusercontent.com/jOOQ/sakila/${SAKILA_DB_COMMIT}"

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

declare -A BACKEND_RESULTS=()
declare -A BACKEND_DETAILS=()
declare -a BACKEND_SEQUENCE=()

print_green() {
  printf '%b\n' "${GREEN}${1}${RESET}"
}

print_red() {
  printf '%b\n' "${RED}${1}${RESET}" >&2
}

trap 'status=$?; if [[ ${status} -eq 0 ]]; then print_green "Smoke test passed."; else print_red "Smoke test failed."; fi; exit ${status}' EXIT

# Run a docker compose subcommand. This keeps the script portable across
# environments where the user sets COMPOSE_CMD to a custom command.
run_compose() {
  if [[ -n "${COMPOSE_CMD:-}" ]]; then
    local -a compose_cmd
    read -r -a compose_cmd <<< "${COMPOSE_CMD}"
    "${compose_cmd[@]}" "$@"
  else
    docker compose "$@"
  fi
}

run_sql_query() {
  local db_name="${1:-postgres}"
  local sql="${2}"

  if [[ "${DB_TYPE}" == "mysql" ]]; then
    run_compose exec -T "${DB_SERVICE_NAME}" mysql --batch --raw --skip-column-names -uroot -p"${DB_ROOT_PASSWORD}" "${db_name}" -e "${sql}"
  else
    run_compose exec -T "${DB_SERVICE_NAME}" psql -U postgres -d "${db_name}" -tAc "${sql}"
  fi
}

export_table_snapshot() {
  local db_name="${1}"
  local table_name="${2}"
  local order_by="${3}"
  local output_file="${4}"

  if [[ "${DB_TYPE}" == "mysql" ]]; then
    local sql
    if [[ -n "${order_by}" ]]; then
      sql="SELECT * FROM \\`\${table_name}\\` ${order_by};"
    else
      sql="SELECT * FROM \\`\${table_name}\\` ;"
    fi
    run_compose exec -T "${DB_SERVICE_NAME}" mysql --batch --raw --skip-column-names -uroot -p"${DB_ROOT_PASSWORD}" "${db_name}" -e "${sql}" > "${output_file}"
  else
    run_compose exec -T "${DB_SERVICE_NAME}" psql -U postgres -d "${db_name}" -q -A -t -c "COPY (SELECT * FROM \"${table_name}\" ${order_by}) TO STDOUT WITH CSV" > "${output_file}"
  fi
}

wait_for_database() {
  local attempt

  for attempt in $(seq 1 "${RETRY_COUNT}"); do
    if [[ "${DB_TYPE}" == "mysql" ]]; then
      if run_compose exec -T "${DB_SERVICE_NAME}" mysqladmin ping -h localhost -uroot -p"${DB_ROOT_PASSWORD}" --silent >/dev/null 2>&1; then
        return 0
      fi
      echo "Waiting for MySQL to become ready (${attempt}/${RETRY_COUNT})..."
    else
      if run_compose exec -T "${DB_SERVICE_NAME}" pg_isready -U postgres >/dev/null 2>&1; then
        return 0
      fi
      echo "Waiting for PostgreSQL to become ready (${attempt}/${RETRY_COUNT})..."
    fi

    sleep "${SLEEP_SECONDS}"
  done

  echo "${DB_TYPE^} did not become ready in time." >&2
  return 1
}

ensure_database_exists() {
  local db_name="$1"
  local exists

  if [[ "${DB_TYPE}" == "mysql" ]]; then
    exists=$(run_compose exec -T "${DB_SERVICE_NAME}" mysql -uroot -p"${DB_ROOT_PASSWORD}" -sN -e "SHOW DATABASES LIKE '${db_name}';")
    if [[ -z "${exists}" ]]; then
      echo "Creating ${db_name} database..."
      run_compose exec -T "${DB_SERVICE_NAME}" bash -lc "mysql -uroot -p${DB_ROOT_PASSWORD} -e \"CREATE DATABASE \\\`$db_name\\\`;\""
    fi
  else
    exists=$(run_sql_query postgres "SELECT 1 FROM pg_database WHERE datname='${db_name}';")
    if [[ "${exists}" != "1" ]]; then
      echo "Creating ${db_name} database..."
      run_compose exec -T "${DB_SERVICE_NAME}" psql -U postgres -d postgres -c "CREATE DATABASE \"${db_name}\";"
    fi
  fi
}

# Intentionally avoid mutating the shared backup configuration file. The smoke test
# uses the explicit database target passed to the backup utility and the container's
# environment variables instead, which keeps the repo config stable while still
# exercising the real backup/restore workflow.
ensure_sakila_data() {
  local table_count

  if [[ "${DB_TYPE}" == "mysql" ]]; then
    table_count=$(run_sql_query "${DB_NAME}" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='actor';")
    if [[ "${table_count}" == "0" ]]; then
      echo "Loading Sakila schema from commit ${SAKILA_DB_COMMIT}..."
      curl -fsSL "${SAKILA_DB_BASE_URL}/mysql-sakila-db/mysql-sakila-schema.sql" | run_compose exec -T -i "${DB_SERVICE_NAME}" mysql -uroot -p"${DB_ROOT_PASSWORD}" "${DB_NAME}"

      echo "Loading Sakila data from commit ${SAKILA_DB_COMMIT}..."
      curl -fsSL "${SAKILA_DB_BASE_URL}/mysql-sakila-db/mysql-sakila-insert-data.sql" | run_compose exec -T -i "${DB_SERVICE_NAME}" mysql -uroot -p"${DB_ROOT_PASSWORD}" "${DB_NAME}"
    fi
  else
    table_count=$(run_sql_query "${DB_NAME}" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='actor';")
    if [[ "${table_count}" == "0" ]]; then
      echo "Loading Sakila schema from commit ${SAKILA_DB_COMMIT}..."
      curl -fsSL "${SAKILA_DB_BASE_URL}/postgres-sakila-db/postgres-sakila-schema.sql" \
        | run_compose exec -T -i "${DB_SERVICE_NAME}" psql -U postgres -d "${DB_NAME}"

      echo "Loading Sakila data from commit ${SAKILA_DB_COMMIT}..."
      curl -fsSL "${SAKILA_DB_BASE_URL}/postgres-sakila-db/postgres-sakila-insert-data.sql" \
        | run_compose exec -T -i "${DB_SERVICE_NAME}" psql -U postgres -d "${DB_NAME}"
    fi
  fi
}

latest_backup_file() {
  run_compose exec -T "${BACKUP_SERVICE_NAME}" bash -lc '
    find /backups -type f -name "*.sql.gz" \
      -printf "%TY-%Tm-%Td %TH:%TM:%TS %p\n" \
      | sort \
      | tail -n 1 \
      | sed "s~^.* \(.*$\)~\1~"'
}

restore_latest_backup() {
  local backup_file

  backup_file="$(latest_backup_file)"

  if [[ -z "${backup_file}" ]]; then
    echo "No backup file found to restore." >&2
    return 1
  fi

  ensure_database_exists "${RESTORE_DB_NAME}"

  echo "Restoring ${backup_file} into ${RESTORE_DB_NAME}..."
  if [[ "${DB_TYPE}" == "mysql" ]]; then
    run_compose exec -T "${BACKUP_SERVICE_NAME}" env CONTAINER_TYPE=mariadb SCHEDULED_RUN=1 DATABASE_SERVICE_NAME=mysql DATABASE_PASSWORD=secret DATABASE_USER=mysql /backup.sh \
      -r "mysql:3306/${RESTORE_DB_NAME}" \
      -a secret \
      -f "${backup_file}"
  else
    run_compose exec -T "${BACKUP_SERVICE_NAME}" env CONTAINER_TYPE=postgres SCHEDULED_RUN=1 DATABASE_SERVICE_NAME=postgresql DATABASE_PASSWORD=secret DATABASE_USER=postgres /backup.sh \
      -r "postgresql:5432/${RESTORE_DB_NAME}" \
      -a secret \
      -f "${backup_file}"
  fi
}

get_table_names() {
  if [[ "${DB_TYPE}" == "mysql" ]]; then
    run_sql_query "${DB_NAME}" "SELECT table_name FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_type='BASE TABLE' ORDER BY table_name;"
  else
    run_sql_query "${DB_NAME}" "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name;"
  fi
}

get_primary_key_column() {
  local table_name="${1}"

  if [[ "${DB_TYPE}" == "mysql" ]]; then
    run_sql_query "${DB_NAME}" "SELECT column_name FROM information_schema.key_column_usage WHERE table_schema='${DB_NAME}' AND table_name='${table_name}' AND constraint_name='PRIMARY' ORDER BY ordinal_position LIMIT 1;"
  else
    run_sql_query "${DB_NAME}" "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${table_name}' AND column_name IN (SELECT column_name FROM information_schema.key_column_usage WHERE table_schema='public' AND table_name='${table_name}' AND constraint_name IN (SELECT constraint_name FROM information_schema.table_constraints WHERE table_schema='public' AND table_name='${table_name}' AND constraint_type='PRIMARY KEY')) ORDER BY ordinal_position LIMIT 1;"
  fi
}

compare_database_data() {
  local table
  local tables
  local source_snapshot
  local restore_snapshot
  local order_by
  local first_pk

  tables=$(get_table_names)

  for table in ${tables}; do
    source_snapshot=$(mktemp)
    restore_snapshot=$(mktemp)
    first_pk=$(get_primary_key_column "${table}")

    if [[ -n "${first_pk}" ]]; then
      if [[ "${DB_TYPE}" == "mysql" ]]; then
        order_by="ORDER BY \\`\${first_pk}\\`"
      else
        order_by="ORDER BY \"${first_pk}\""
      fi
    else
      order_by=""
    fi

    echo "Comparing table ${table}..."
    export_table_snapshot "${DB_NAME}" "${table}" "${order_by}" "${source_snapshot}"
    export_table_snapshot "${RESTORE_DB_NAME}" "${table}" "${order_by}" "${restore_snapshot}"

    if ! diff -u "${source_snapshot}" "${restore_snapshot}"; then
      echo "Data mismatch detected for table: ${table}" >&2
      rm -f "${source_snapshot}" "${restore_snapshot}"
      return 1
    fi

    rm -f "${source_snapshot}" "${restore_snapshot}"
  done

  echo "All restored tables match the original source data."
}

run_backup_smoke_test() {
  local backend_result=0

  echo "Running backup.sh -1..."
  if [[ "${DB_TYPE}" == "mysql" ]]; then
    if ! run_compose exec -T "${BACKUP_SERVICE_NAME}" env \
      CONTAINER_TYPE=mariadb \
      DATABASE_SERVICE_NAME=mysql \
      DATABASE_PASSWORD="${DB_PASSWORD}" \
      DATABASE_USER="${DB_USER}" \
      /backup.sh -1 > /tmp/backup-container-smoke.log 2>&1; then
      backend_result=1
    fi
  else
    if ! run_compose exec -T "${BACKUP_SERVICE_NAME}" env \
      CONTAINER_TYPE=postgres \
      DATABASE_SERVICE_NAME=postgresql \
      DATABASE_PASSWORD="${DB_PASSWORD}" \
      DATABASE_USER="${DB_USER}" \
      /backup.sh -1 > /tmp/backup-container-smoke.log 2>&1; then
      backend_result=1
    fi
  fi

  if (( backend_result == 0 )); then
    echo "Latest backup files:"
    run_compose exec -T "${BACKUP_SERVICE_NAME}" bash -lc '
      find /backups -type f -name "*.sql.gz" \
        -printf "%TY-%Tm-%Td %TH:%TM:%TS %p\n" \
        | sort \
        | tail -n 5'

    if ! restore_latest_backup; then
      backend_result=1
    elif ! compare_database_data; then
      backend_result=1
    fi
  fi

  if (( backend_result == 0 )); then
    BACKEND_RESULTS["${DB_TYPE}"]="PASS"
    BACKEND_DETAILS["${DB_TYPE}"]="Backup created, restored into ${RESTORE_DB_NAME}, and all rows matched the source data."
  else
    BACKEND_RESULTS["${DB_TYPE}"]="FAIL"
    BACKEND_DETAILS["${DB_TYPE}"]="Backup or restore step failed, or restored table data did not match the source database."
  fi

  return ${backend_result}
}

print_test_summary() {
  local backend
  local summary_exit=0

  echo
  echo "=== Smoke test summary ==="
  for backend in "${BACKEND_SEQUENCE[@]}"; do
    if [[ "${BACKEND_RESULTS[${backend}]:-FAIL}" == "PASS" ]]; then
      printf '%-8s: PASS - %s\n' "${backend}" "${BACKEND_DETAILS[${backend}]:-No details recorded.}"
    else
      printf '%-8s: FAIL - %s\n' "${backend}" "${BACKEND_DETAILS[${backend}]:-No details recorded.}"
      summary_exit=1
    fi
  done

  if (( summary_exit == 0 )); then
    print_green "Overall result: PASS"
  else
    print_red "Overall result: FAIL"
  fi

  return ${summary_exit}
}

main() {
  local backend
  local -a backends=()
  local overall_exit=0

  if [[ -n "${DB_TYPES:-}" ]]; then
    IFS=',' read -r -a backends <<< "${DB_TYPES}"
  else
    backends=("${DB_TYPE}")
  fi
  BACKEND_SEQUENCE=("${backends[@]}")

  for backend in "${backends[@]}"; do
    DB_TYPE="${backend}"
    apply_backend_settings

    if [[ "${DB_TYPE}" != "postgres" && "${DB_TYPE}" != "mysql" ]]; then
      echo "Unsupported DB_TYPE '${DB_TYPE}'. Supported values: postgres, mysql." >&2
      exit 1
    fi

    if ! run_compose ps >/dev/null 2>&1; then
      echo "Compose stack is not running. Run: docker compose up -d --build first."
      exit 1
    fi

    echo "=== Running smoke test for ${DB_TYPE} backend ==="
    if ! wait_for_database; then
      BACKEND_RESULTS["${DB_TYPE}"]="FAIL"
      BACKEND_DETAILS["${DB_TYPE}"]="Database service never became ready."
      overall_exit=1
      continue
    fi

    if ! ensure_database_exists "${DB_NAME}"; then
      BACKEND_RESULTS["${DB_TYPE}"]="FAIL"
      BACKEND_DETAILS["${DB_TYPE}"]="Source database could not be created."
      overall_exit=1
      continue
    fi

    if ! ensure_sakila_data; then
      BACKEND_RESULTS["${DB_TYPE}"]="FAIL"
      BACKEND_DETAILS["${DB_TYPE}"]="Sakila sample data could not be loaded."
      overall_exit=1
      continue
    fi

    if ! run_backup_smoke_test; then
      overall_exit=1
    fi
  done

  print_test_summary
  exit ${overall_exit}
}

main "$@"
