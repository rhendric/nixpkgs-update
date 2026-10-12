{
  description = "update nixpkgs automatically";

  inputs.mmdoc.url = "github:ryantm/mmdoc";
  inputs.mmdoc.inputs.nixpkgs.follows = "nixpkgs";

  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

  inputs.runtimeDeps.url = "github:NixOS/nixpkgs/nixos-unstable-small";

  outputs = { self, nixpkgs, mmdoc, treefmt-nix, runtimeDeps }:
    let
      inherit (builtins) mapAttrs zipAttrsWith;
      inherit (nixpkgs.lib)
        genAttrs
        mapAttrs'
        mapAttrsToList
        mergeAttrsList
        mkForce
        nameValuePair
        ;

      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      eachSystem = f: genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
      treefmtEval = eachSystem (
        system: pkgs:
        treefmt-nix.lib.evalModule pkgs {
          build.wrapper = mkForce (
            pkgs.writeShellApplication {
              name = "treefmt";
              runtimeInputs = packageEval.${system}.devShell.nativeBuildInputs;
              inheritPath = false;
              text = ''exec treefmt "$@"'';
            }
          );
        }
      );
      packageEval = eachSystem (
        system: pkgs:
        import ./. {
          inherit pkgs system;
          mmdoc =
            pkgs.lib.recursiveUpdate
              (mmdoc.packages.${system}.mmdoc.overrideAttrs {
                # Unit tests have been broken on aarch64-linux since 0.20
                ${if system == "aarch64-linux" then "doCheck" else null} = false;
              })
              {
                meta.mainProgram = "mmdoc";
              };
          runtimePkgs = runtimeDeps.legacyPackages.${system};
        }
      );
    in
    {
      checks = zipAttrsWith (_: mergeAttrsList) (
        mapAttrsToList (k: mapAttrs (_: mapAttrs' (n: nameValuePair "${k}-${n}"))) {
          treefmt = mapAttrs (_: m: { default = m.config.build.check self; }) treefmtEval;
          package = self.packages;
          devShell = self.devShells;
        }
      );

      formatter = mapAttrs (_: m: m.config.build.wrapper) treefmtEval;

      packages = mapAttrs (_: pkg: {
        default = pkg;
        nixpkgs-update = pkg;
        inherit (pkg) nixpkgs-update-doc;
      }) packageEval;

      devShells = mapAttrs (_: pkg: { default = pkg.devShell; }) packageEval;
    };
}
