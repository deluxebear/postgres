#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

echo "Repository: $root"
echo
echo "Branch:"
git status --short --branch

echo
echo "Recent commits:"
git log --oneline -5

echo
echo "Custom extension files:"
find nix/ext -maxdepth 2 \( -name '*durable*' -o -name '*pg_*' \) -print | sort | sed 's/^/  /'

echo
echo "Release workflow:"
if [ -f .github/workflows/upstream-pg17-release-build.yml ]; then
  ruby -e 'require "yaml"; YAML.load_file(".github/workflows/upstream-pg17-release-build.yml"); puts "  yaml ok"'
  if command -v actionlint >/dev/null 2>&1; then
    actionlint .github/workflows/upstream-pg17-release-build.yml
    echo "  actionlint ok"
  else
    echo "  actionlint not installed"
  fi
else
  echo "  missing .github/workflows/upstream-pg17-release-build.yml"
fi

echo
echo "Preload references:"
rg -n "shared_preload_libraries|pg_durable|orioledb" \
  nix/packages/postgres.nix \
  nix/tools/run-server.sh.in \
  ansible/tasks/stage2-setup-postgres.yml \
  docker/pgctld \
  Dockerfile-17 Dockerfile-orioledb-17 Dockerfile-multigres || true
