#!/usr/bin/env bash
# Smoke test for the local backup workflow.
#
# This script validates the end-to-end backup/restore behavior for the project's
# real database plugins and library functions. It is intentionally not a
# self-contained database bootstrapper: the source database is expected to exist
# and already contain the data you want to protect.
#
# The smoke test flow is:
#   1. confirm the source database is already available
#   2. create a backup archive
#   3. restore the newest backup into a second database
#   4. compare each restored table against the source data
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
#   COMPOSE_CMD                  default: docker compose
#   RETRY_COUNT                  default: 30
#   SLEEP_SECONDS                default: 2
#   DB_TYPE                      default: postgres
#   DB_TYPES                     default: postgres,mysql
#   SOURCE_DB_NAME               default: sakila
#   RESTORE_DB_NAME              default: sakila_restore
#   SMOKE_TEST_BOOTSTRAP_DB      default: 0
#   SMOKE_TEST_BOOTSTRAP_SAKILA  default: 0
#
# The smoke test is designed to validate a database plugin against a real source
# database. The default path expects the source database to already exist in the
# environment under test. The bootstrap variables below are purely a local
# convenience for isolated validation runs and are not part of the normal plugin
# contract.
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
SOURCE_DB_NAME="${SOURCE_DB_NAME:-${DB_NAME:-sakila}}"
DB_NAME="${SOURCE_DB_NAME}"
RESTORE_DB_NAME="${RESTORE_DB_NAME:-sakila_restore}"
SMOKE_TEST_BOOTSTRAP_DB="${SMOKE_TEST_BOOTSTRAP_DB:-0}"
SMOKE_TEST_BOOTSTRAP_SAKILA="${SMOKE_TEST_BOOTSTRAP_SAKILA:-0}"

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

print_backend_banner() {
  local backend="${1}"
  local color="\033[1;33m"

  if [[ "${backend}" == "mysql" ]]; then
    color="\033[1;35m"
  elif [[ "${backend}" == "postgres" ]]; then
    color="\033[1;34m"
  fi

  printf '%b\n' "${color}=== Running smoke test for ${backend} backend ===${RESET}"
}

print_backend_context() {
  local backend="${1}"
  printf 'Source DB: %s | Restore DB: %s | backup service: %s\n' \
    "${DB_NAME}" "${RESTORE_DB_NAME}" "${BACKUP_SERVICE_NAME}"
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
      sql=$(printf 'SELECT * FROM `%s` %s;' "${table_name}" "${order_by}")
    else
      sql=$(printf 'SELECT * FROM `%s`;' "${table_name}")
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
  else
    exists=$(run_sql_query postgres "SELECT 1 FROM pg_database WHERE datname='${db_name}';")
  fi

  if [[ -z "${exists}" ]]; then
    if [[ "${SMOKE_TEST_BOOTSTRAP_DB}" == "1" ]]; then
      echo "Creating ${db_name} database..."
      if [[ "${DB_TYPE}" == "mysql" ]]; then
        run_compose exec -T "${DB_SERVICE_NAME}" bash -lc "mysql -uroot -p${DB_ROOT_PASSWORD} -e \"CREATE DATABASE \\\`$db_name\\\`;\""
      else
        run_compose exec -T "${DB_SERVICE_NAME}" psql -U postgres -d postgres -c "CREATE DATABASE \"${db_name}\";"
      fi
      return 0
    fi

    echo "Smoke test expects the source database '${db_name}' to exist before it runs. This harness validates the plugin/library behavior, not database bootstrap." >&2
    return 1
  fi

  return 0
}

# This harness is expected to validate the actual backup/restore library paths.
# Database creation and seed data loading are intentionally optional and should be
# handled by the environment under test rather than by this script by default.
ensure_sakila_data() {
  if [[ "${SMOKE_TEST_BOOTSTRAP_DB}" != "1" ]]; then
    return 0
  fi

  if [[ "${SMOKE_TEST_BOOTSTRAP_SAKILA}" != "1" ]]; then
    return 0
  fi

  local table_count

  if [[ "${DB_TYPE}" == "mysql" ]]; then
    table_count=$(run_sql_query "${DB_NAME}" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='actor';")
    if [[ "${table_count}" == "0" ]]; then
      echo "Optional local bootstrap enabled: loading Sakila schema..."
      curl -fsSL "https://raw.githubusercontent.com/jOOQ/sakila/main/mysql-sakila-db/mysql-sakila-schema.sql" | run_compose exec -T -i "${DB_SERVICE_NAME}" mysql -uroot -p"${DB_ROOT_PASSWORD}" "${DB_NAME}"

      echo "Optional local bootstrap enabled: loading Sakila data..."
      curl -fsSL "https://raw.githubusercontent.com/jOOQ/sakila/main/mysql-sakila-db/mysql-sakila-insert-data.sql" | run_compose exec -T -i "${DB_SERVICE_NAME}" mysql -uroot -p"${DB_ROOT_PASSWORD}" "${DB_NAME}"
    fi
  else
    table_count=$(run_sql_query "${DB_NAME}" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='actor';")
    if [[ "${table_count}" == "0" ]]; then
      echo "Optional local bootstrap enabled: loading PostgreSQL Sakila schema..."
      curl -fsSL "https://raw.githubusercontent.com/jOOQ/sakila/main/postgres-sakila-db/postgres-sakila-schema.sql" \
        | run_compose exec -T -i "${DB_SERVICE_NAME}" psql -U postgres -d "${DB_NAME}"

      echo "Optional local bootstrap enabled: loading PostgreSQL Sakila data..."
      curl -fsSL "https://raw.githubusercontent.com/jOOQ/sakila/main/postgres-sakila-db/postgres-sakila-insert-data.sql" \
        | run_compose exec -T -i "${DB_SERVICE_NAME}" psql -U postgres -d "${DB_NAME}"
    fi
  fi
}

write_backup_config() {
  local config_path="/tmp/smoke-test-backup.conf"
  local backup_spec="${DB_SERVICE_NAME}:${DB_PORT}/${DB_NAME}"

  run_compose exec -T "${BACKUP_SERVICE_NAME}" bash -lc "cat > '${config_path}' <<EOF
${backup_spec}
EOF
chmod 600 '${config_path}'"
}

latest_backup_file() {
  local backup_prefix="${DB_SERVICE_NAME}-${DB_NAME}"

  run_compose exec -T "${BACKUP_SERVICE_NAME}" bash -lc "
    find /backups -type f -name '${backup_prefix}_*.sql.gz' \
      -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\\n' \
      | sort \
      | tail -n 1 \
      | sed 's~^.* \\(.*$\\)~\\1~'"
}

clear_backend_backups() {
  local backup_prefix="${DB_SERVICE_NAME}-${DB_NAME}"
  local active_db_pattern="*-${DB_NAME}_*.sql.gz"

  echo "Clearing stale backups for ${DB_TYPE} backend before the new smoke-test backup..."
  run_compose exec -T "${BACKUP_SERVICE_NAME}" bash -lc "
    find /backups -type f \( -name '${backup_prefix}_*.sql.gz' -o -name '${backup_prefix}_*.sql.gz.in_progress' -o -name '${active_db_pattern}' -o -name '${DB_NAME}_*.sql.gz' -o -name '${DB_NAME}_*.sql.gz.in_progress' \) -delete"
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
    local restore_mode_env=(
      CONTAINER_TYPE=mariadb
      SCHEDULED_RUN=1
      DATABASE_SERVICE_NAME=mysql
      DATABASE_PASSWORD="${DB_PASSWORD}"
      DATABASE_USER="${DB_USER}"
      MYSQL_RESTORE_PRIVILEGED_MODE="${MYSQL_RESTORE_PRIVILEGED_MODE:-0}"
      MYSQL_RESTORE_USER="${MYSQL_RESTORE_USER:-root}"
      MYSQL_RESTORE_PASSWORD="${MYSQL_RESTORE_PASSWORD:-${DB_ROOT_PASSWORD}}"
    )

    run_compose exec -T "${BACKUP_SERVICE_NAME}" env \
      "${restore_mode_env[@]}" \
      /backup.sh \
      -r "mysql:3306/${RESTORE_DB_NAME}" \
      -a "${DB_ROOT_PASSWORD}" \
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
        order_by=$(printf 'ORDER BY `%s`' "${first_pk}")
      else
        order_by=$(printf 'ORDER BY "%s"' "${first_pk}")
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

  clear_backend_backups

  echo "Running backup.sh -1..."
  if [[ "${DB_TYPE}" == "mysql" ]]; then
    write_backup_config
    if ! run_compose exec -T "${BACKUP_SERVICE_NAME}" env \
      CONTAINER_TYPE=mariadb \
      MYSQLDUMP_SET_GTID_PURGED=OFF \
      MYSQLDUMP_SKIP_DEFINER=1 \
      MYSQLDUMP_SKIP_VIEWS=1 \
      MYSQLDUMP_SKIP_ROUTINES=1 \
      MYSQLDUMP_SKIP_TRIGGERS=1 \
      MYSQLDUMP_SKIP_EVENTS=1 \
      DATABASE_SERVICE_NAME=mysql \
      DATABASE_PASSWORD="${DB_PASSWORD}" \
      DATABASE_USER="${DB_USER}" \
      MYSQL_DATABASE="${DB_NAME}" \
      POSTGRESQL_DATABASE="${DB_NAME}" \
      BACKUP_CONF=/tmp/smoke-test-backup.conf \
      /backup.sh -1 > /tmp/backup-container-smoke.log 2>&1; then
      backend_result=1
      echo "MySQL backup creation failed; aborting restore/compare for this backend." >&2
    fi
  else
    write_backup_config
    if ! run_compose exec -T "${BACKUP_SERVICE_NAME}" env \
      CONTAINER_TYPE=postgres \
      DATABASE_SERVICE_NAME=postgresql \
      DATABASE_PASSWORD="${DB_PASSWORD}" \
      DATABASE_USER="${DB_USER}" \
      POSTGRESQL_DATABASE="${DB_NAME}" \
      MYSQL_DATABASE="${DB_NAME}" \
      BACKUP_CONF=/tmp/smoke-test-backup.conf \
      /backup.sh -1 > /tmp/backup-container-smoke.log 2>&1; then
      backend_result=1
    fi
  fi

  if (( backend_result == 0 )); then
    echo "Latest backup files for ${DB_TYPE}/${DB_NAME}:"
    run_compose exec -T "${BACKUP_SERVICE_NAME}" bash -lc "
      find /backups -type f -name '${DB_SERVICE_NAME}-${DB_NAME}_*.sql.gz' \
        -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' \
        | sort \
        | tail -n 5"

    if ! restore_latest_backup; then
      backend_result=1
      echo "Restore failed for ${DB_TYPE}; stopping before comparison." >&2
    elif ! compare_database_data; then
      backend_result=1
      echo "Data comparison failed for ${DB_TYPE}; restore did not match source data." >&2
    fi
  fi

  # Some MySQL/MariaDB restore failures do not exit non-zero even though the SQL
  # stream contains an actual SQL error. Keep the final backend result honest and
  # avoid a false-positive PASS when a restore fails in the middle of the dump
  # stream. Match only SQL error lines that start with the real MySQL error
  # prefix; do not treat backup warnings such as `mysqldump: Error:` as a restore
  # failure.
  if (( backend_result == 0 )) && [[ "${DB_TYPE}" == "mysql" ]] && [[ -f "/tmp/backup-container-smoke.log" ]] && grep -Eq '^[[:space:]]*ERROR [0-9]{3} ' /tmp/backup-container-smoke.log; then
    backend_result=1
    echo "Detected a restore-related error in the MySQL smoke-test log; marking backend as failed." >&2
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

mark_backend_failed() {
  local backend="${1}"
  local reason="${2}"
  BACKEND_RESULTS["${backend}"]="FAIL"
  BACKEND_DETAILS["${backend}"]="${reason}"
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

    print_backend_banner "${DB_TYPE}"
    print_backend_context "${DB_TYPE}"
    if ! wait_for_database; then
      mark_backend_failed "${DB_TYPE}" "Database service never became ready."
      overall_exit=1
      continue
    fi

    if ! ensure_database_exists "${DB_NAME}"; then
      mark_backend_failed "${DB_TYPE}" "Source database is not available for the smoke test. Create or prepare it outside the harness, or enable SMOKE_TEST_BOOTSTRAP_DB=1 for a local convenience bootstrap."
      overall_exit=1
      continue
    fi

    if ! ensure_sakila_data; then
      mark_backend_failed "${DB_TYPE}" "Optional bootstrap data could not be loaded."
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
