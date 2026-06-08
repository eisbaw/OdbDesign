{
  description = "OdbDesign C++ ODB++ parser, nixified (CLI + libs only, no REST/gRPC, no tests)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        odbdesign = pkgs.stdenv.mkDerivation {
          pname = "odbdesign";
          version = "unstable-2026-04-19";

          # Point at the local upstream clone (sibling dir).
          src = ./.;

          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            pkg-config
            autoPatchelfHook  # rewrites RPATH to cover libstdc++ + buildInputs
            makeWrapper       # wraps binaries with PATH containing p7zip
          ];

          buildInputs = with pkgs; [
            libarchive
            zlib
            crow
            protobuf
            grpc
            stdenv.cc.cc.lib  # libstdc++.so.6
          ];

          # Runtime PATH dependency: Utils/ArchiveExtractor shells out to `7z`
          # via std::system() to extract ODB++ .tgz archives.
          # (Yes -- libarchive is linked but not used for extraction.)
          propagatedBuildInputs = [ pkgs.p7zip ];

          # 1) Excise the FetchContent(GoogleTest) block (lines 33-42) -- the
          #    nix sandbox forbids network at build time.
          # 2) Drop the test/server subprojects (we only build lib + CLI).
          # 3) Drop precompiled headers (PCH ordering is a frequent pain
          #    point under generators; build is fast enough without).
          postPatch = ''
            # The FetchContent block is contiguous and uniquely identifiable.
            sed -i '/^include(FetchContent)$/,/^enable_testing()$/d' CMakeLists.txt

            substituteInPlace CMakeLists.txt \
              --replace-fail 'add_subdirectory("OdbDesignServer")' '# add_subdirectory("OdbDesignServer")' \
              --replace-fail 'add_subdirectory("OdbDesignTests")' '# add_subdirectory("OdbDesignTests")'

            # Add our local odb-dump CLI subproject.
            echo 'add_subdirectory("OdbDump")' >> CMakeLists.txt

            for f in OdbDesignLib/CMakeLists.txt OdbDesignApp/CMakeLists.txt Utils/CMakeLists.txt; do
              substituteInPlace "$f" \
                --replace-quiet 'target_precompile_headers' '# target_precompile_headers'
            done

            # Fix upstream slicing bug: `throw e;` inside `catch(std::exception&)`
            # copies into a std::exception base and loses derived type info, so
            # the caller never learns whether it was a parse_error / runtime_error
            # / etc. The correct form is `throw;` (which preserves the active
            # exception). Touches 7 sites in FileModel/Design/*.cpp.
            for f in OdbDesignLib/FileModel/Design/AttrListFile.cpp \
                     OdbDesignLib/FileModel/Design/ComponentsFile.cpp \
                     OdbDesignLib/FileModel/Design/EdaDataFile.cpp \
                     OdbDesignLib/FileModel/Design/FeaturesFile.cpp \
                     OdbDesignLib/FileModel/Design/MiscInfoFile.cpp \
                     OdbDesignLib/FileModel/Design/NetlistFile.cpp \
                     OdbDesignLib/FileModel/Design/ToolsFile.cpp; do
              substituteInPlace "$f" --replace-quiet 'throw e;' 'throw;'
            done

            # Show 7z stdout/stderr so we can see when extraction misbehaves.
            substituteInPlace Utils/ArchiveExtractor.h \
              --replace-fail 'HIDE_7Z_COMMAND_OUTPUT = true' \
                             'HIDE_7Z_COMMAND_OUTPUT = false'

            # Upstream parser bug: FeaturesFile::Parse() unconditionally
            # requires a `features` file in every layer directory. The ODB++
            # spec says component-typed layers carry a `components` file
            # instead (see steps/<step>/matrix). On real boards (e.g. Valor
            # NPI exports with comp_+_top / comp_+_bot layers) this aborts
            # the whole design build.
            # Patch: if no features file exists, return true with an empty
            # feature list. This is safe for our consumer (Design::Build()
            # ignores feature geometry; we only need components + nets).
            substituteInPlace OdbDesignLib/FileModel/Design/FeaturesFile.cpp \
              --replace-fail 'auto message = "features file does not exist: [" + m_path.string() + "]";' \
                             'auto message = "features file does not exist: [" + m_path.string() + "]"; loginfo(message + " (treating as empty layer)"); return true;'
          '';

          cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            # Stop CMake from looking for vcpkg toolchain
            "-DVCPKG_MANIFEST_MODE=OFF"
            # Don't bake build-dir RPATHs into binaries; autoPatchelfHook
            # adds the correct $out/lib + buildInput RPATHs at fixup time.
            "-DCMAKE_SKIP_BUILD_RPATH=ON"
          ];

          # Upstream lacks install() rules, so we install by hand.
          # autoPatchelfHook (nativeBuildInputs) then rewrites RPATH on every
          # ELF under $out so libstdc++ + buildInput libs resolve at runtime.
          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin $out/lib $out/include/OdbDesign

            find . -maxdepth 4 -type f \( -name 'lib*.so' -o -name 'lib*.so.*' \) \
              -exec install -m755 {} $out/lib/ \;
            find . -maxdepth 4 -type f -executable -name 'OdbDesignApp' \
              -exec install -m755 {} $out/bin/ \;
            find . -maxdepth 4 -type f -executable -name 'odb-dump' \
              -exec install -m755 {} $out/bin/ \;

            (cd OdbDesignLib && find . -name '*.h' -exec install -D -m644 {} $out/include/OdbDesign/{} \;)

            # Wrap the CLIs so they can find `7z` at runtime.
            for b in $out/bin/odb-dump $out/bin/OdbDesignApp; do
              wrapProgram "$b" --prefix PATH : ${pkgs.p7zip}/bin
            done

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "ODB++ Design archive parser (CLI + library, no REST/gRPC)";
            homepage = "https://github.com/nam20485/OdbDesign";
            license = licenses.agpl3Only;
            platforms = platforms.unix;
            mainProgram = "OdbDesignApp";
          };
        };

      in {
        packages.default = odbdesign;
        packages.odbdesign = odbdesign;

        apps.default = {
          type = "app";
          program = "${odbdesign}/bin/OdbDesignApp";
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ odbdesign ];
          packages = with pkgs; [ ccache gdb ];
        };
      });
}
