#!/usr/bin/env bash
# Build only the previous pg_durable release and its exact PostgreSQL flavor.
set -euo pipefail
export PG_DURABLE_TEST_FLAVOR=${1:?PostgreSQL flavor is required}
PG_DURABLE_FLAKE_ROOT=$(pwd)
export PG_DURABLE_FLAKE_ROOT
previous_file=nix/ext/pg_durable-ci-previous.nix
expression=$(mktemp --suffix=.nix)
trap 'rm -f "$previous_file" "$expression"' EXIT

python3 - <<'PY'
from pathlib import Path
src = Path('nix/ext/pg_durable.nix').read_text()
assert 'version = "0.2.9";' in src
src = src.replace('version = "0.2.9";', 'version = "0.2.8";')
src = src.replace('sha256-bwTe3awgBPKFT8Uz/xRR5+hzHQoTIYQv97xyrBXWBwc=', 'sha256-OuYYakh1AAUgyu8vT9tWjpscvbJysaBtEnJW6JDtw8s=')
src = src.replace('sha256-2TlyaUKXudH910/w12CiRg3+6JL57/S225Y3nFWJraY=', 'sha256-xld22By+Mt8oGsiJTp7/N3J0cYriBO4VgOB7Ou/tDVY=')
src = src.replace('"pg${pgMajor}"', '"pg${pgMajor}"\n      "http-allow-azure-domains"')
Path('nix/ext/pg_durable-ci-previous.nix').write_text(src)
PY

cat > "$expression" <<'NIX'
let
  root = builtins.getEnv "PG_DURABLE_FLAKE_ROOT";
  flavor = builtins.getEnv "PG_DURABLE_TEST_FLAVOR";
  flake = builtins.getFlake "path:${root}";
  system = builtins.currentSystem;
  pkgs = import flake.inputs.nixpkgs {
    inherit system;
    overlays = [ (import flake.inputs.rust-overlay) ];
  };
  postgresql = flake.packages.${system}."postgresql_${flavor}";
  durable = pkgs.callPackage (root + "/nix/ext/pg_durable-ci-previous.nix") {
    inherit postgresql;
  };
  oriole = pkgs.callPackage (root + "/nix/ext/orioledb.nix") {
    inherit postgresql;
  };
in postgresql.withPackages (_: [ durable ] ++ pkgs.lib.optional (flavor == "orioledb-17") oriole)
NIX
nix build --impure --accept-flake-config --file "$expression" -L --out-link previous-pg-durable
