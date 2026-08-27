# Project Patterns

## GitHub Release Discovery And Compatibility Gate

For each extension explicitly named by the user:

1. Resolve the official GitHub repository from the existing Nix source, project README, or the user's input. Cross-check repository ownership before using a similarly named project.
2. Inspect the repository's Releases list or GitHub API, not only a package registry or search result. Exclude drafts, GitHub prereleases, and versions identified by upstream as alpha, beta, RC, preview, development, or nightly builds. Respect an upstream version scheme when it is not semantic versioning.
3. Compare the latest stable release with every version or revision currently selected by `nix/ext/versions.json`, the extension's Nix expression, `ansible/vars.yml`, `common-nix.vars.yml`, and relevant documentation. Record the chosen release tag, URL, and publication date.
4. Read release notes from the current version through the candidate version for PostgreSQL support changes, breaking SQL/API changes, upgrade scripts, dependency/toolchain changes, new preload requirements, configuration changes, and data migration or dump/restore warnings.
5. Establish compatibility separately for each requested target (for example, standard PG17 and OrioleDB17). Use evidence in this order:
   - upstream's support matrix, README, release notes, or maintained documentation
   - the exact release's build metadata and CI matrix, such as `Cargo.toml`, pgrx features, `pg_config` checks, Makefiles, and tested PostgreSQL majors
   - a build plus extension install/upgrade tests against the repository's exact target package
6. Treat upstream support claims as necessary evidence, not a substitute for a local build. Treat a successful standard PostgreSQL build as no evidence of OrioleDB ABI compatibility. For OrioleDB, inspect any PostgreSQL server API or ABI touched by the extension and run its OrioleDB target build and tests independently.

The gate passes only when the exact candidate release can be packaged reproducibly and the relevant build and extension lifecycle tests pass for every requested target. A small source or packaging adaptation is acceptable when it is scoped, maintainable, and covered by tests. Do not carry a speculative compatibility patch, silently downgrade from the latest stable release, drop an existing target, or update only part of the requested target set without the user's approval.

If no stable GitHub release exists, the repository is archived/unverifiable, upstream excludes a requested PostgreSQL target, the required adaptation is invasive, or validation fails, retain the current pin and report the current version, candidate version, compatibility evidence, failing target, and recommended next decision.

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

For upgrades, follow the extension's existing package structure:

- For `versions.json` packages, add the new release entry with its exact supported PostgreSQL majors and fixed hash; preserve prior versions needed for upgrade testing.
- For direct Nix expressions, update every source version/revision and fixed-output hash consistently.
- For Rust/pgrx packages, derive the pgrx and Rust toolchain requirements from the candidate release, refresh Cargo inputs or hashes, and retain `previouslyPackagedVersions` entries needed to validate SQL upgrade paths.
- Remove or refresh local patches only after checking whether the upstream release incorporated them. Keep any remaining patch narrow and document why it is still needed.

See `nix/docs/update-extension.md` for this repository's detailed versioned-package and legacy-package procedures.

## README Synchronization

After a compatible release is actually selected and packaged, update the root `README.md` and any extension-specific README or docs affected by the change. At minimum keep these facts aligned with the code:

- current stable extension version and official GitHub repository
- standard PostgreSQL and OrioleDB package targets that actually passed the gate
- preload and runtime configuration requirements
- compatibility exclusions and their concrete reason
- versioned commands, examples, release notes, or file paths that changed

Do not update a documented version merely because a newer GitHub release exists; the README must describe the version that is pinned and validated in the repository.

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
