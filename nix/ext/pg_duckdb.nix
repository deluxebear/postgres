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
  version = "1.1.1";

  src = fetchurl {
    url = "https://github.com/duckdb/pg_duckdb/archive/refs/tags/v${version}.tar.gz";
    hash = "sha256-F2O9RgsxyfM7Ht8Lu8UN2P9bj6ClZtBTJG7Ouy2mrNk=";
  };

  duckdbSrc = fetchurl {
    url = "https://github.com/duckdb/duckdb/archive/d1dc88f950d456d72493df452dabdcd13aa413dd.tar.gz";
    hash = "sha256-dRHh9QnOnBCpXArli8RVHUsBWx3FZk9FN7L24SDEyR8=";
  };

  httpfsSrc = fetchurl {
    url = "https://github.com/duckdb/duckdb-httpfs/archive/9c7d34977b10346d0b4cbbde5df807d1dab0b2bf.tar.gz";
    hash = "sha256-2Ttof3k+Z038+deETI5yZRJucIQ4mXvuTuAcMvtBKAM=";
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
          EXTENSION_VERSION 9c7d34977b
      )
      EOF

      mkdir -p .git/modules/third_party/duckdb
      touch .git/modules/third_party/duckdb/HEAD
    ''
    + lib.optionalString (postgresql.isOrioleDB or false) ''
      perl -0pi -e 's/\n\s*\.tuple_insert_speculative = duckdb_tuple_insert_speculative,\n\s*\.tuple_complete_speculative = duckdb_tuple_complete_speculative,//' src/pgduckdb_table_am.cpp
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
