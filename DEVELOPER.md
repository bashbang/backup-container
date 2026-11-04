## Docker

This project contains a docker-compose.yml file suitable for development purposes. It will start a PostgreSQL database, MinIO-compatible S3 storage, and a backup container.

Note: the legacy `minio/minio` Docker Hub image has been removed. This repo uses the maintained `quay.io/minio/aistor/minio:latest` image so local development continues to work without a Docker Hub login.

Because all the bash scripts are mounted to root `/`, the docker-compose file mounts them individually. If you wish to add new files, create them and then add them to the backup container mounts. This method allows you to edit the files on the host and have changes immediately available in the container. You may need to restart the backup process to see the changes.

To start the containers run:

```bash
docker compose up -d --build
```

Once all 3 containers start they will create three folders that are **not** tracked by git:

- `./pg-data` - PostgreSQL database
- `./minio-data` - MinIO storage
- `./backups` - backup archives

NOTE: MinIO needs at least 1G of free space to function properly. Make sure you have some free local space.

Add this shell (bash or zsh) alias to quickly connect to a container by name:

```bash
dcon='function _dcon(){ docker exec -i -t $1 /bin/bash -c "export COLUMNS=`tput cols`; export LINES=`tput lines`; exec bash"; };_dcon'
```

Use `docker ps` to list all running containers and then use `dcon <container_name>` to connect to the container.

```bash
dcon backup-container-postgresql-1
```

### Protips 🤓

- Newer Docker releases do not require the hyphen. `docker compose` is preferred over `docker-compose`.
- This bash one-liner was used to add all the files to the backup container volumes:

```bash
ls docker/ | grep 'backup\.' | awk '{ print "- ./docker/"$1":/"$1 }'
```

## Smoke test

The project includes a smoke test that validates the real backup/restore behavior of the configured database plugins and the shared backup library itself.

What it does:

1. Verifies that the source database already exists for the selected backend.
2. Runs the backup command to produce a `.sql.gz` archive.
3. Locates the newest backup for that database/backend.
4. Restores that backup into a second database (`sakila_restore` by default).
5. Exports each table from both databases to a stable, ordered snapshot.
6. Compares the snapshot and exits non-zero on any mismatch.

This is the working validation strategy for the smoke test: compare the actual table data from the source and restored databases rather than comparing raw dump output, which may include engine-specific metadata and can differ even when the underlying data matches.

The smoke test is intentionally not a self-contained database bootstrapper. It validates the plugin/library path against a real source database that already exists in the environment under test. That keeps the smoke test focused on the functionality we actually want to verify: backup, restore, and data integrity behavior.

For a local convenience bootstrap, you may opt in to creating and seeding a sample database with:

```bash
SMOKE_TEST_BOOTSTRAP_DB=1 SMOKE_TEST_BOOTSTRAP_SAKILA=1 bash scripts/smoke-test.sh
```

That is optional; the default path expects the database and its application data to be prepared outside of the smoke test itself.

Run the smoke test after the stack is up:

```bash
docker compose up -d --build
bash scripts/smoke-test.sh
```

The default matrix is both PostgreSQL and MySQL in a single run. You can limit it explicitly:

```bash
DB_TYPES=postgres bash scripts/smoke-test.sh
DB_TYPES=mysql bash scripts/smoke-test.sh
```

The restore step explicitly sets `CONTAINER_TYPE` for the active backend (`postgres` or `mariadb`) before invoking the shared backup utility. This is intentional and prevents the generic restore path from falling back to the default auto-detected container type, which could otherwise pick the wrong plugin and attempt to connect to the wrong database service during a MySQL restore. The smoke test therefore exercises the real shared backup script without mutating repo config files.

For MySQL/MariaDB backups, the default smoke-test path is intentionally data-only: it disables GTID purge metadata (`--set-gtid-purged=OFF`), strips DEFINER metadata, and skips routines/triggers/events unless an explicit full-object flow is requested. This keeps the normal plugin behavior focused on data validation without changing the default production behavior for users who do not need privileged object restores.

If you intentionally need to validate a full-object dump that includes routines, triggers, or event definitions, opt into the explicit privileged restore path by setting `MYSQL_RESTORE_PRIVILEGED_MODE=1` and, if needed, `MYSQL_RESTORE_USER`/`MYSQL_RESTORE_PASSWORD` for a restore account that can set `log_bin_trust_function_creators = 1` on the target server. This is a deliberate compatibility mode for constrained or smoke-test restore environments, not the default behavior.

The script prints progress as it creates the database, loads Sakila data, runs the backup, restores the archive, and compares the table contents. If all backends pass, the final output includes a per-backend status line and:

```text
Overall result: PASS
```

On a typical local development machine, the combined smoke test completes in roughly 30-60 seconds once the Docker stack is already running.

## Postgres

Connect to the postgres container using the `dcon` alias noted above and create the database, schema, and sample data.

Connect to the postgres container:

```bash
dcon backup-container-postgresql-1
```

Run the `psql` command to connect to the database and create the database:

```bash
psql -U postgres
create database sakila;
^D
```

Run the following two commands to create the schema and insert the data. If `curl` is not installed, run `apt-get update && apt-get install curl` first.

```bash
curl -sSL https://raw.githubusercontent.com/jOOQ/sakila/main/postgres-sakila-db/postgres-sakila-schema.sql | psql -U postgres -d sakila;
```

```bash
curl -sSL https://raw.githubusercontent.com/jOOQ/sakila/main/postgres-sakila-db/postgres-sakila-insert-data.sql | psql -U postgres -d sakila;
```

You should now have a sample database with data.
