{
  lib,
  stdenv,
  buildEnv,
  fetchurl,
  postgresql,
  cmake,
  git,
  ninja,
  pkg-config,
  python3,
  curl,
  lz4,
  openssl,
}:

let
  pname = "pg_duckdb";
  version = "1.2.2";

  src = fetchurl {
    url = "https://github.com/duckdb/pg_duckdb/archive/refs/tags/v${version}.tar.gz";
    hash = "sha256-53ez3z87qbuHKfaK0pAB7itO5T9WvRXVU5qpirCydWo=";
  };

  duckdbSrc = fetchurl {
    url = "https://github.com/duckdb/duckdb/archive/8d78114e90a53823803660bf821f6073ac87da8c.tar.gz";
    hash = "sha256-CbXHdXtBQn2jjwAdgPtRcm3v/pNnz/kqySIQ2Lvrfb4=";
  };

  httpfsSrc = fetchurl {
    url = "https://github.com/duckdb/duckdb-httpfs/archive/f71cfdb4bff85b9e15b1f3b842d9aa395aff0167.tar.gz";
    hash = "sha256-6jXqOLs0YNxsYDuMRn0GXp7L91beG+JlmMV8UmoO0j4=";
  };

  extension = stdenv.mkDerivation {
    inherit pname version src;

    nativeBuildInputs = [
      cmake
      git
      ninja
      pkg-config
      python3
    ];

    buildInputs = [
      curl
      lz4
      openssl
      postgresql
    ];

    dontUseCmakeConfigure = true;
    dontUseNinjaBuild = true;
    dontConfigure = true;

    postPatch = ''
      rm -rf third_party/duckdb
      mkdir -p third_party/duckdb
      tar -xzf ${duckdbSrc} --strip-components=1 -C third_party/duckdb

      rm -rf third_party/duckdb-httpfs
      mkdir -p third_party/duckdb-httpfs
      tar -xzf ${httpfsSrc} --strip-components=1 -C third_party/duckdb-httpfs

      substituteInPlace third_party/pg_duckdb_extensions.cmake \
        --replace-fail 'GIT_URL https://github.com/duckdb/duckdb-httpfs' 'SOURCE_DIR ''${CMAKE_CURRENT_LIST_DIR}/duckdb-httpfs' \
        --replace-fail 'GIT_TAG f71cfdb4bff85b9e15b1f3b842d9aa395aff0167' 'EXTENSION_VERSION f71cfdb4bf'

      mkdir -p .git/modules/third_party/duckdb
      touch .git/modules/third_party/duckdb/HEAD
    '';

    makeFlags = [
      "PG_CONFIG=${postgresql}/bin/pg_config"
      "PG_DUCKDB_VERSION=v${version}"
      "DUCKDB_BUILD=ReleaseStaticSystem"
      "DUCKDB_GEN=ninja"
      "DUCKDB_DISABLE_ASSERTIONS=1"
    ];

    enableParallelBuilding = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/{lib,share/postgresql/extension}
      install -Dm755 ${pname}${postgresql.dlSuffix} $out/lib/${pname}${postgresql.dlSuffix}
      install -Dm644 ${pname}.control $out/share/postgresql/extension/${pname}.control
      install -Dm644 sql/${pname}--*.sql -t $out/share/postgresql/extension

      runHook postInstall
    '';

    doCheck = false;

    meta = with lib; {
      description = "DuckDB Embedded in Postgres";
      homepage = "https://github.com/duckdb/pg_duckdb";
      license = licenses.mit;
      inherit (postgresql.meta) platforms;
    };
  };
in
buildEnv {
  name = pname;
  paths = [ extension ];
  pathsToLink = [
    "/lib"
    "/share/postgresql/extension"
  ];

  passthru = {
    inherit pname version;
    hasBackgroundWorker = true;
    defaultSettings = {
      shared_preload_libraries = [ "pg_duckdb" ];
    };
  };
}
