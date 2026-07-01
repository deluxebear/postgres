---
name: postgres-custom-extension-build
description: Project-local workflow for adding custom PostgreSQL extensions to this Supabase Postgres fork. Use when asked to add, update, validate, build, or release a custom extension such as pg_durable for PostgreSQL 17 or OrioleDB 17, including Nix packaging, shared_preload_libraries wiring, upstream release patching, native amd64 and arm64 GitHub Actions builds, Docker Hub publishing, and GitHub releases that tag the patched upstream source tree.
---

# Postgres Custom Extension Build

## Scope

Use this skill only inside this repository. Keep custom extension work isolated from upstream build logic where possible:

- Maintain customization on `custom-extensions/pg-durable` or another dedicated `custom-extensions/<name>` branch.
- Treat Supabase upstream releases as the source baseline.
- Generate a narrow patch from the custom branch and apply it onto the selected upstream release tag in CI.
- Build both standard PG17 and OrioleDB17 when the extension supports both.
- Prefer native architecture runners over QEMU for Nix builds.

Read `references/project-patterns.md` before making substantive changes.

## Workflow

1. Inspect the repo state with `scripts/check_repo_state.sh` and `git status --short --branch`.
2. Identify the extension source, latest stable release, license, PostgreSQL version support, build system, preload requirements, and runtime configuration.
3. Add the extension as a Nix package under `nix/ext/<extension>.nix`.
4. Add the extension only to the intended package set in `nix/packages/postgres.nix`.
5. If the extension requires preload, append it without replacing existing libraries in:
   - `nix/tools/run-server.sh.in`
   - `ansible/tasks/stage2-setup-postgres.yml`
   - PG17 Dockerfile(s)
   - `docker/pgctld/*.tmpl`
6. Update extension interface tests and expected outputs only for intentional interface changes.
7. Keep `.github/workflows/upstream-pg17-release-build.yml` as the release automation entrypoint:
   - discover latest stable Supabase PG17 release tags, excluding test releases
   - checkout upstream release source
   - apply only the custom patch paths
   - build Nix on native `amd64` and `arm64`
   - push Docker architecture tags and merge manifests
   - create GitHub releases from tags pointing at patched upstream source commits
8. Validate locally with static checks before pushing.

## Release Rules

- Do not tag releases at the workflow branch commit.
- Recreate the patched upstream source tree in the release job, commit it, push a source tag, then create the release from that tag.
- Do not add extension names such as `pg-durable` to final Docker image version tags unless the user explicitly asks.
- Use final Docker tags matching upstream versions, for example `17.6.1.141` and `17.6.0.098-orioledb`.
- Use intermediate architecture tags only for manifest assembly, for example `17.6.1.141-amd64` and `17.6.1.141-arm64`.

## Validation

Run at minimum:

```bash
git diff --check
actionlint .github/workflows/upstream-pg17-release-build.yml
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/upstream-pg17-release-build.yml"); puts "yaml ok"'
```

When feasible, trigger the GitHub Action on the custom branch and inspect:

- `Discover upstream PG17 releases`
- `Build 17 amd64`
- `Build 17 arm64`
- `Build orioledb-17 amd64`
- `Build orioledb-17 arm64`
- `Publish manifest`
- `Publish GitHub release`

## Cautions

- Do not force-push or delete tags without explicit user approval.
- Do not revert unrelated user changes.
- Do not broaden patch paths casually; patch drift is the main failure mode when upstream releases change.
- Check whether `shared_preload_libraries` values are appended, not overwritten.
- If an extension has no stable release, ask before pinning a commit.
