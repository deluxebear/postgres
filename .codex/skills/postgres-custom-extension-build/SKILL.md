---
name: postgres-custom-extension-build
description: Project-local workflow for adding or upgrading custom PostgreSQL extensions in this Supabase Postgres fork. Use when asked to add, update, validate, build, or release an extension for PostgreSQL 17 or OrioleDB 17; it checks the extension's official GitHub releases and target-PostgreSQL compatibility before updating Nix packaging, runtime wiring, tests, README documentation, and release automation.
---

# Postgres Custom Extension Build

## Scope

Use this skill only inside this repository. Keep custom extension work isolated from upstream build logic where possible:

- Maintain customization on `custom-extensions/pg-durable` or another dedicated `custom-extensions/<name>` branch.
- Treat Supabase upstream releases as the source baseline.
- Generate a narrow patch from the custom branch and apply it onto the selected upstream release tag in CI.
- For every extension named by the user, check its official GitHub repository for the latest stable release; do not assume the repository's currently pinned version is current.
- Update to that release only after the requested PostgreSQL major and flavor pass the compatibility gate. Treat standard PostgreSQL and OrioleDB as separate targets.
- Build both standard PG17 and OrioleDB17 when the extension supports both.
- Prefer native architecture runners over QEMU for Nix builds.

Read `references/project-patterns.md` before making substantive changes. When upgrading an existing extension, also read `nix/docs/update-extension.md` and follow the package structure already used by that extension.

## Workflow

1. Inspect the repo state with `scripts/check_repo_state.sh` and `git status --short --branch`.
2. Resolve each requested extension's official GitHub repository, current pin, latest stable release, license, build system, preload requirements, and intended PostgreSQL targets. Record the release URL and tag as upgrade evidence.
3. Apply the compatibility gate in `references/project-patterns.md`: inspect upstream support declarations and release notes, then build and test the exact release against every intended PostgreSQL target. Do not infer OrioleDB compatibility from PostgreSQL-major compatibility.
4. If the gate passes, update the extension to the latest stable release. Update all relevant pins and integrity data, including version/revision, source hash, Cargo hash or lock data, pgrx/Rust requirements, patches, and SQL upgrade paths. For a new extension, add its Nix package under `nix/ext/<extension>.nix`.
5. Add or retain the extension only in compatible package sets in `nix/packages/postgres.nix`. Do not silently remove an existing target or perform a partial upgrade when the requested target set does not all pass; report the incompatibility and ask before changing scope.
6. If the extension requires preload, append it without replacing existing libraries in:
   - `nix/tools/run-server.sh.in`
   - `ansible/tasks/stage2-setup-postgres.yml`
   - PG17 Dockerfile(s)
   - `docker/pgctld/*.tmpl`
7. Update extension installation, upgrade, interface, dump/restore, and expected-output tests as required by the upstream release. Change snapshots only for intentional interface changes.
8. Update the repository `README.md` and any extension-specific documentation so the version, upstream URL, supported PostgreSQL targets, preload behavior, compatibility limitations, and versioned examples match the implementation.
9. Keep `.github/workflows/upstream-pg17-release-build.yml` as the release automation entrypoint:
   - discover latest stable Supabase PG17 release tags, excluding test releases
   - checkout upstream release source
   - apply only the custom patch paths
   - build Nix on native `amd64` and `arm64`
   - push Docker architecture tags and merge manifests
   - create GitHub releases from tags pointing at patched upstream source commits
10. Validate locally with static checks plus the narrowest Nix builds and extension tests that cover every changed PostgreSQL target before pushing.

## Release Rules

- Do not tag releases at the workflow branch commit.
- Recreate the patched upstream source tree in the release job, commit it, push a source tag, then create the release from that tag.
- Do not add extension names such as `pg-durable` to final Docker image version tags unless the user explicitly asks.
- Use final Docker tags matching upstream versions, for example `17.6.1.141` and `17.6.0.098-orioledb`.
- Use intermediate architecture tags only for manifest assembly, for example `17.6.1.141-amd64` and `17.6.1.141-arm64`.

## Validation

For an extension upgrade, verify at minimum:

- the resolved source is the exact stable GitHub release tag recorded during discovery
- each intended PostgreSQL target builds the extension from the updated pin
- `CREATE EXTENSION` succeeds, and supported upgrades from the previously packaged version succeed
- extension interface tests pass for each target; run migration or dump/restore checks when the release changes on-disk state or SQL objects
- all fixed-output hashes and generated lock data are committed, with no placeholder hashes

Then run:

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
- Do not treat a draft, prerelease, release candidate, preview, nightly build, or arbitrary tag/commit as the latest stable release.
- If an extension has no stable GitHub release, ask before pinning a tag or commit.
- If the latest stable release cannot support every requested PostgreSQL target after a narrow, maintainable adaptation, leave the existing version and target set intact and report the evidence and blocker.
