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
  version = "1.2.0";
  # Upstream has not tagged v1.2.0 yet. Pin the current main commit whose
  # control file reports 1.2.0; the latest GitHub release remains v1.1.1.
  rev = "ee38d3b540ecea1d93683ba99bdcec5632a21eaf";

  src = fetchurl {
    url = "https://github.com/duckdb/pg_duckdb/archive/${rev}.tar.gz";
    hash = "sha256-ZLE1HAVxXnMyVO8dO9YKeF3u/dsolvwLHEv0+bfxba0=";
  };

  duckdbSrc = fetchurl {
    url = "https://github.com/duckdb/duckdb/archive/08e34c447bae34eaee3723cac61f2878b6bdf787.tar.gz";
    hash = "sha256-Det4u1PdUDAyNQOy8/9dUtZq95adzx84SaID18dp5IE=";
  };

  httpfsSrc = fetchurl {
    url = "https://github.com/duckdb/duckdb-httpfs/archive/c3f215ab360f04dc3d3d5305fa81849c0121f111.tar.gz";
    hash = "sha256-69od5lyqLspPWJHaRiWDkp/VcXoqeCJ/bk3R/61wDfc=";
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

      cat > third_party/pg_duckdb_extensions.cmake <<'EOF'
      duckdb_extension_load(json)
      duckdb_extension_load(icu)
      duckdb_extension_load(httpfs
          SOURCE_DIR ''${CMAKE_CURRENT_LIST_DIR}/duckdb-httpfs
          EXTENSION_VERSION c3f215ab36
      )
      EOF

      mkdir -p .git/modules/third_party/duckdb
      touch .git/modules/third_party/duckdb/HEAD
    '';

    makeFlags = [
      "PG_CONFIG=${postgresql}/bin/pg_config"
      "DUCKDB_BUILD=ReleaseStatic"
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
