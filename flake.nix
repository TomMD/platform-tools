{
  description = "Anza platform-tools - Solana/SBF toolchain (Rust + LLVM/Clang)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        version = "1.53";

        # Determine host triple and artifact name based on system
        hostTriple = {
          "x86_64-linux" = "x86_64-unknown-linux-gnu";
          "aarch64-linux" = "aarch64-unknown-linux-gnu";
          "x86_64-darwin" = "x86_64-apple-darwin";
          "aarch64-darwin" = "aarch64-apple-darwin";
        }.${system} or (throw "Unsupported system: ${system}");

        artifactName = {
          "x86_64-linux" = "platform-tools-linux-x86_64.tar.bz2";
          "aarch64-linux" = "platform-tools-linux-aarch64.tar.bz2";
          "x86_64-darwin" = "platform-tools-osx-x86_64.tar.bz2";
          "aarch64-darwin" = "platform-tools-osx-aarch64.tar.bz2";
        }.${system} or (throw "Unsupported system: ${system}");

        # SHA256 hashes for pre-built binaries (update these for new releases)
        # To get hash: nix-prefetch-url "https://github.com/anza-xyz/platform-tools/releases/download/v${version}/${artifactName}"
        # Or run `nix build` and it will show the expected hash in the error
        artifactHash = {
          "x86_64-linux" = "sha256-h2tcKUo41B1AvtRZKREJHpLMPzmd0XoPnKyHsd+asSA=";
          "aarch64-linux" = "sha256-xDFPYspfOtKd9uERVHLKWEC/zt6C0Vjr0ri/A8CTHjA=";
          "x86_64-darwin" = "sha256-RucOgyBjLiGfbfr3Ke87z1tP9mr+orLTlKAVkSnlXVk=";
          "aarch64-darwin" = "sha256-I5vFF/RzIN0bCg01URyktm9xZ5x5oKa6+XjDuDia0js=";
        }.${system} or (throw "Unsupported system: ${system}");

        # Binary distribution - fetches pre-built release from GitHub
        # This is much faster than building from source
        anza-platform-tools = pkgs.stdenv.mkDerivation {
          pname = "anza-platform-tools";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/anza-xyz/platform-tools/releases/download/v${version}/${artifactName}";
            hash = artifactHash;
          };

          nativeBuildInputs = with pkgs; [ autoPatchelfHook ];

          buildInputs = with pkgs; [
            stdenv.cc.cc.lib
            zlib
            ncurses
            libffi
          ];

          # LLDB was built against Ubuntu 22.04 libraries with different soversions
          # These are optional - rustc, cargo, clang work fine without them
          autoPatchelfIgnoreMissingDeps = [
            "libpython3.10.so.1.0"
            "libxml2.so.2"
            "libedit.so.2"
            "liblzma.so.5"
          ];

          dontStrip = true;

          unpackPhase = ''
            mkdir -p $out
            tar -xjf $src -C $out
          '';

          # Remove broken symlinks before fixup phase checks them
          preFixup = ''
            # Remove broken LLDB Python symlinks (LLDB dependencies aren't fully available on NixOS)
            find $out -xtype l -delete 2>/dev/null || true
          '';

          installPhase = ''
            # Structure is already correct from tarball
            # Just need to set up wrapper scripts if needed

            # Make binaries executable
            chmod -R +x $out/rust/bin/* 2>/dev/null || true
            chmod -R +x $out/llvm/bin/* 2>/dev/null || true
          '';

          meta = with pkgs.lib; {
            description = "Anza platform-tools - Solana/SBF development toolchain (pre-built binary)";
            homepage = "https://github.com/anza-xyz/platform-tools";
            license = with licenses; [ asl20 mit ];
            platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
          };
        };

        # Source-based build - uses the build.sh script
        # WARNING: This takes several hours and requires ~50GB disk space
        # Also requires __noChroot = true in your nix config (or use --impure)
        platform-tools-source = pkgs.stdenv.mkDerivation {
          pname = "platform-tools";
          inherit version;

          src = ./.;

          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            python3
            pkg-config
            git
            curl
            cacert
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            swig
            libedit
            ncurses
            libxml2
            rustup
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            darwin.apple_sdk.frameworks.Security
            darwin.apple_sdk.frameworks.CoreFoundation
            darwin.apple_sdk.frameworks.SystemConfiguration
          ];

          buildInputs = with pkgs; [
            openssl
            openssl.dev
            zlib
            libffi
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            libedit
            ncurses
            libxml2
          ];

          dontStrip = true;
          enableParallelBuilding = true;

          # Network access required to clone repos and submodules
          __noChroot = true;

          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          GIT_SSL_CAINFO = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

          OPENSSL_DIR = "${pkgs.openssl.dev}";
          OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
          OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
          OPENSSL_STATIC = "1";

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            export RUSTUP_HOME=$TMPDIR/.rustup
            export CARGO_HOME=$TMPDIR/.cargo

            # Install rust toolchain
            rustup-init -y --default-toolchain 1.89.0 --no-modify-path
            export PATH="$CARGO_HOME/bin:$PATH"

            # Run the upstream build script
            ./build.sh build_out

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            # Extract the built tarball
            mkdir -p $out
            tar -xjf platform-tools-*.tar.bz2 -C $out

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Anza platform-tools - Solana/SBF development toolchain (source build)";
            homepage = "https://github.com/anza-xyz/platform-tools";
            license = with licenses; [ asl20 mit ];
            platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
          };
        };

      in {
        packages = {
          # Default to binary for speed - source build takes hours
          default = anza-platform-tools;
          source = platform-tools-source;
          platform-tools = anza-platform-tools;
          inherit anza-platform-tools platform-tools-source;
        };

        # Development shell with platform-tools available
        devShells.default = pkgs.mkShell {
          packages = [ anza-platform-tools ];
          shellHook = ''
            export PATH="${anza-platform-tools}/rust/bin:${anza-platform-tools}/llvm/bin:$PATH"
            echo "Anza platform-tools v${version} available"
            echo "  rustc: $(rustc --version 2>/dev/null || echo 'not found')"
            echo "  cargo: $(cargo --version 2>/dev/null || echo 'not found')"
            echo "  clang: $(clang --version 2>/dev/null | head -1 || echo 'not found')"
          '';
        };

        # Shell for building from source
        devShells.build = pkgs.mkShell {
          packages = with pkgs; [
            cmake
            ninja
            python3
            pkg-config
            git
            curl
            cacert
            openssl
            openssl.dev
            zlib
            libffi
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            swig
            libedit
            ncurses
            libxml2
            rustup
          ];

          shellHook = ''
            echo "Build environment for platform-tools"
            echo "Run ./build.sh to build from source"
          '';
        };
      }
    );
}
