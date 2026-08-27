{
  lib,
  stdenv,
  buildEnv,
  fetchurl,
  postgresql,
  callPackages,
  rust-bin,
  openssl,
}:

let
  pname = "pg_durable";
  version = "0.2.6";
  rustVersion = "1.88.0";
  pgrxVersion = "0.16.1";
  pgMajor = if postgresql.isOrioleDB or false then "17" else lib.versions.major postgresql.version;

  cargo = rust-bin.stable.${rustVersion}.default;
  mkPgrxExtension = callPackages ../cargo-pgrx/mkPgrxExtension.nix {
    inherit rustVersion pgrxVersion;
  };

  extension = mkPgrxExtension rec {
    inherit pname version postgresql;

    src = fetchurl {
      url = "https://github.com/microsoft/pg_durable/releases/download/v${version}/pg_durable-${version}.tar.gz";
      hash = "sha256-VLfdddc2GES+wBzhZF2hOwo8WD4+Jag4JJslwa6sjmA=";
    };

    nativeBuildInputs = [ cargo ];
    buildInputs = [
      openssl
      postgresql
    ];

    CARGO = "${cargo}/bin/cargo";

    cargoLock = {
      lockFile = fetchurl {
        url = "https://raw.githubusercontent.com/microsoft/pg_durable/v${version}/Cargo.lock";
        hash = "sha256-p5lpbmzGIEEKqvUxSOSmP8hxD7B93/YC1yVCPVHPZEw=";
      };
    };

    buildFeatures = [
      "pg${pgMajor}"
      "http-allow-azure-domains"
    ];

    env = {
      OPENSSL_DIR = "${openssl.dev}";
      OPENSSL_INCLUDE_DIR = "${openssl.dev}/include";
      OPENSSL_LIB_DIR = "${openssl.out}/lib";
      PKG_CONFIG_PATH = "${openssl.dev}/lib/pkgconfig";
    }
    // lib.optionalAttrs stdenv.isDarwin {
      POSTGRES_LIB = "${postgresql}/lib";
      RUSTFLAGS = "-C link-arg=-undefined -C link-arg=dynamic_lookup";
    };

    doCheck = false;

    meta = with lib; {
      description = "Durable SQL Functions for PostgreSQL";
      homepage = "https://github.com/microsoft/pg_durable";
      license = licenses.postgresql;
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
      shared_preload_libraries = [ "pg_durable" ];
    };
  };
}
