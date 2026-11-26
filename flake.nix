{
  description = "leansplice: unified diffs for Lean";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        let
          version = pkgs.lib.removePrefix "leanprover/lean4:v" (
            pkgs.lib.strings.trim (builtins.readFile ./lean-toolchain)
          );
          release =
            {
              x86_64-linux = {
                platform = "linux";
                sha256 = "2b7ab1ed8b92d2e6abfaf41344823b510064dbc9c0260cac73eb496ab2dea6eb";
              };
              aarch64-darwin = {
                platform = "darwin_aarch64";
                sha256 = "49acada8749ad1343eff1224a3d2510ac61ed53363d37b5e738e8c587e7deabd";
              };
            }
            .${system};
          lean = pkgs.stdenv.mkDerivation {
            pname = "lean4";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://github.com/leanprover/lean4/releases/download/v${version}/lean-${version}-${release.platform}.tar.zst";
              inherit (release) sha256;
            };
            nativeBuildInputs = [
              pkgs.zstd
            ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
            buildInputs = pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.stdenv.cc.cc.lib;
            dontBuild = true;
            dontStrip = true;
            installPhase = ''
              mkdir -p "$out"
              cp -r bin include lib share src "$out/"
            '';
          };
        in
        {
          treefmt.programs.nixfmt.enable = true;
          devShells.default = pkgs.mkShell {
            packages = [
              lean
              pkgs.git
              pkgs.gnumake
            ];
            LEAN_CC = "${pkgs.stdenv.cc}/bin/cc";
          };
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "leansplice";
            inherit (builtins.fromTOML (builtins.readFile ./lakefile.toml)) version;
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./lakefile.toml
                ./lake-manifest.json
                ./lean-toolchain
                ./Leansplice.lean
                ./Main.lean
                ./LICENSE
              ];
            };
            nativeBuildInputs = [ lean ];
            LEAN_CC = "${pkgs.stdenv.cc}/bin/cc";
            buildPhase = "lake build";
            installPhase = ''
              install -Dm755 .lake/build/bin/leansplice "$out/bin/leansplice"
              install -Dm644 LICENSE "$out/share/licenses/leansplice/LICENSE"
            '';
            meta.mainProgram = "leansplice";
          };
        };
    };
}
