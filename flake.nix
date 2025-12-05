{
  description = "Project Neo";
  inputs = {
    crane.url = "github:ipetkov/crane";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };

    nixpkgs.url = "nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      crane,
      fenix,
      flake-utils,
      advisory-db,
      nixpkgs,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        inherit (pkgs) lib;

        craneLib =
          (crane.mkLib nixpkgs.legacyPackages.${system}).overrideToolchain
            fenix.packages.${system}.default.toolchain;

        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            (lib.fileset.fromSource (craneLib.cleanCargoSource ./.))
            ./openmls/README.md
            ./README.md
          ];
        };

        commonArgs = {
          inherit src;
          strictDeps = true;

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.protobuf
            pkgs.protoc-gen-rust
          ];

          buildInputs = [
            pkgs.openssl
          ];
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        individualCrateArgs = commonArgs // {
          inherit cargoArtifacts;
          inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
          # NB: we disable tests since we'll run them all via cargo-nextest
          doCheck = false;
        };

        fileSetForCrate =
          crate:
          lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./openmls
              ./README.md
              ./openmls/README.md
              # (craneLib.fileset.commonCargoSources ./openmls)
              (craneLib.fileset.commonCargoSources ./libcrux_crypto)
              (craneLib.fileset.commonCargoSources ./basic_credential)
              (craneLib.fileset.commonCargoSources ./traits)
              (craneLib.fileset.commonCargoSources ./memory_storage)
              (craneLib.fileset.commonCargoSources ./sqlite_storage)
              (craneLib.fileset.commonCargoSources ./openmls_rust_crypto)
              (craneLib.fileset.commonCargoSources ./openmls_test)
              (craneLib.fileset.commonCargoSources ./fuzz)
              (craneLib.fileset.commonCargoSources ./cli)
              (craneLib.fileset.commonCargoSources ./delivery-service/ds-lib)
              (craneLib.fileset.commonCargoSources ./delivery-service/ds)
              (craneLib.fileset.commonCargoSources ./sqlx_storage)
              (craneLib.fileset.commonCargoSources ./openmls-wasm)
              (craneLib.fileset.commonCargoSources crate)
            ];
          };

        openmls-libcrux-crypto = craneLib.buildPackage (
          individualCrateArgs
          // {
            pname = "openmls_libcrux_crypto";
            version = "0.1.0";
            cargoExtraArgs = "-p openmls_libcrux_crypto";
            src = fileSetForCrate ./libcrux_crypto;
          }
        );

        openmls-basic-credential = craneLib.buildPackage (
          individualCrateArgs
          // {
            pname = "openmls_basic_credential";
            version = "0.1.0";
            cargoExtraArgs = "-p openmls_basic_credential";
            src = fileSetForCrate ./basic_credential;
          }
        );

        openmls = craneLib.buildPackage (
          individualCrateArgs
          // {
            pname = "openmls";
            version = "0.1.0";
            cargoExtraArgs = "-p openmls";
            src = fileSetForCrate ./openmls;
          }
        );

      in
      {
        checks = {
          inherit
            openmls
            ;

          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          my-workspace-clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            }
          );

          my-workspace-doc = craneLib.cargoDoc (
            commonArgs
            // {
              inherit cargoArtifacts;
              env.RUSTDOCFLAGS = "--deny warnings";
            }
          );

          # Check formatting
          my-workspace-fmt = craneLib.cargoFmt {
            inherit src;
          };

          my-workspace-toml-fmt = craneLib.taploFmt {
            src = pkgs.lib.sources.sourceFilesBySuffices src [ ".toml" ];
          };

          # Audit dependencies
          my-workspace-audit = craneLib.cargoAudit {
            inherit src advisory-db;
          };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on other crate derivations
          # if you do not want the tests to run twice
          my-workspace-nextest = craneLib.cargoNextest (
            commonArgs
            // {
              inherit cargoArtifacts;
              partitions = 1;
              partitionType = "count";
              cargoNextestPartitionsExtraArgs = "--no-tests=pass";
            }
          );

          my-workspace-hakari = craneLib.mkCargoDerivation {
            inherit src;
            pname = "my-workspace-hakari";
            cargoArtifacts = null;
            doInstallCargoArtifacts = false;

            buildPhaseCargoCommand = ''
              cargo hakari generate --diff  # workspace-hack Cargo.toml is up-to-date
              cargo hakari manage-deps --dry-run  # all workspace crates depend on workspace-hack
              cargo hakari verify
            '';

            nativeBuildInputs = [
              pkgs.cargo-hakari
            ];
          };
        }; # checks

        packages = {
          inherit openmls;
          default = openmls;
        };

        apps = {
        };

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};

          PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";

          LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.openssl ];

          packages = [
            pkgs.cargo-hakari
            pkgs.cargo-watch
            pkgs.rust-analyzer
            pkgs.taplo
            pkgs.openapi-generator-cli
            pkgs.openssl
            pkgs.pkg-config
          ];
        };
      }
    );
}
