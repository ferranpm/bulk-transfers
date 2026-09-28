# 17. Development environment

Status: Accepted (2026-09-28)

## Context

Reviewers must be able to run the service and its tests without installing Ruby or PostgreSQL locally, and
AI agents working on the repo need one unambiguous place to run commands. The provided setup was Docker
Compose with Postgres 14.2 and a `DATABASE_NAME` variable. Running tools on the host as well as in the
container risks "works on my machine" differences (Ruby version, native `pg` build, database host).

## Chosen

- Docker Compose with `postgres:17-alpine`. The web image is built from the repo's `Dockerfile` and includes
  `git`, which bundler-audit needs to fetch its advisory database.
- `config/database.yml` reads `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`, `DATABASE_PASSWORD` with
  fixed database names (`qonto_development`, `qonto_test`). `DATABASE_NAME` is removed from compose.
- Gems live in a named volume (`bundle_cache`), so a Gemfile change needs `bundle install`, not an image rebuild.
- **No entrypoint.** Reviewers run `docker compose run --rm web bin/setup` (bundle install, `db:prepare`,
  seeds) once, then `docker compose up`.
- Agents run everything via `docker compose exec web ...`.
- Multiple instances are proven by the concurrency specs, not by compose.

## Discarded (why)

- **An entrypoint that runs bundle and `db:prepare` on every `up`**: the user declined it. It hides setup
  failures inside container start-up and slows every restart.
- **Baking gems into the image**: rebuild on every Gemfile change.
- **Keeping Postgres 14.2**: no reason to start a new service on an older major version.
- **An nginx + two replicas demo**: moved to "Not built yet". The concurrency specs exercise the same race
  with separate connections.
- **Running specs on the host**: the container is the single source of truth.

## Consequences

- `docker compose up` alone doesn't create the database on a fresh clone. The README's setup section runs
  `bin/setup` first.
- Upgrading an existing Postgres 14 volume requires `docker compose down -v` (data loss, acceptable for a dev DB).
- Compose exports `RAILS_ENV=development`, so `spec/rails_helper.rb` forces `test`.
