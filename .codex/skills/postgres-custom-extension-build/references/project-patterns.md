# Project Patterns

## Branch And Patch Model

Use a dedicated branch for custom extension work, currently `custom-extensions/pg-durable`.

The custom branch contains only the maintained customization. The GitHub Action checks out a Supabase upstream release tag into `upstream`, generates a patch from the custom branch relative to that tag, applies it to `upstream`, then builds from that patched tree.

Keep `patch_paths` in `.github/workflows/upstream-pg17-release-build.yml` narrow and explicit. Include only files required by the extension packaging, build, runtime preload, tests, and Docker release path.

## Existing pg_durable Pattern

The current extension pattern is:

- Nix package: `nix/ext/pg_durable.nix`
- Package inclusion: `pg17OnlyExtensions` in `nix/packages/postgres.nix`
- Targets:
  - `psql_17`
  - `psql_17_slim`
  - `psql_orioledb-17`
  - `psql_orioledb-17_slim`
- Runtime preload append:
  - `pg_durable`
  - OrioleDB images append both `orioledb` and `pg_durable`

Use the same pattern for future PG17-only extensions unless compatibility requires a different package set.

## Nix Packaging

Prefer fixed upstream release tarballs and fixed hashes. For Rust/pgrx extensions, pin:

- extension release version
- cargo dependencies or Cargo.lock source
- pgrx version
- cargo hash

The package should expose extension files under standard PostgreSQL paths:

- `lib/postgresql`
- `share/postgresql/extension`

If an extension needs preload, set extension metadata or package passthrough consistently with local patterns, but still wire runtime config where this repository expects it.

## shared_preload_libraries

Append libraries; do not replace existing settings. Existing extensions such as `pg_cron`, `pg_net`, `pgsodium`, `supautils`, and `orioledb` may also need preload.

When editing SQL templates, Dockerfiles, shell scripts, or Ansible tasks, search all occurrences:

```bash
rg -n "shared_preload_libraries|session_preload_libraries|pg_durable|orioledb" \
  nix ansible docker Dockerfile*
```

## GitHub Action Release Flow

The release workflow must:

1. Discover latest stable Supabase PG17 releases from `supabase/postgres`, excluding draft, prerelease, and any release/tag/name containing `test`.
2. Build a matrix for standard PG17 and OrioleDB17.
3. Build each release on native architecture runners:
   - `amd64`: `ubuntu-latest`
   - `arm64`: `ubuntu-24.04-arm`
4. Run Nix build before Docker build on each architecture.
5. Push Docker architecture tags:
   - `<version>-amd64`
   - `<version>-arm64`
6. Merge architecture tags into:
   - `<version>`
   - floating flavor tag such as `17` or `orioledb-17`
7. Recreate the patched upstream source tree in the release job.
8. Commit that patched source tree and tag it in this repo.
9. Create or update a GitHub Release from that source tag.

The release tag should not be named `custom-*` unless explicitly requested. Current pattern:

- `postgres-17.6.1.141`
- `postgres-17.6.0.098-orioledb`

## Docker Hub

Use:

- `secrets.DOCKER_USERNAME`
- `secrets.DOCKER_PASSWORD`
- optional `vars.DOCKERHUB_REPOSITORY`

If `DOCKERHUB_REPOSITORY` is unset, default to `${DOCKER_USERNAME}/postgres`.

Do not include extension names in final image version tags unless requested.

## Common Checks

Use:

```bash
git diff --check
actionlint .github/workflows/upstream-pg17-release-build.yml
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/upstream-pg17-release-build.yml"); puts "yaml ok"'
```

Inspect Actions with:

```bash
gh run list --repo deluxebear/postgres --branch custom-extensions/pg-durable --limit 8
gh run view <run-id> --repo deluxebear/postgres --json status,conclusion,jobs,url
```
