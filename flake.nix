{
  description = "A flake for nixpkgs-update";

  inputs.nixpkgs-review.url = "github:mic92/nixpkgs-review";
  inputs.flake-compat = { url = "github:edolstra/flake-compat"; flake = false; };
  inputs.nixpkgs = { type = "github"; owner = "nixos"; repo = "nixpkgs"; };
  inputs.mmdoc.url = "github:ryantm/mmdoc";

  nixConfig.extra-substituters = [ "https://nixpkgs-update.cachix.org" ];
  nixConfig.extra-trusted-public-keys = [ "nixpkgs-update.cachix.org-1:6y6Z2JdoL3APdu6/+Iy8eZX2ajf09e4EE9SnxSML1W8=" ];

  outputs = { self, flake-compat, nixpkgs, nixpkgs-review, mmdoc } @ args:
    {
      packages."x86_64-linux" = import ./pkgs/default.nix (args // { system = "x86_64-linux"; });
      defaultPackage."x86_64-linux" = self.packages."x86_64-linux".nixpkgs-update;
      devShell."x86_64-linux" = self.packages."x86_64-linux".devShell;

      packages."x86_64-darwin" = import ./pkgs/default.nix (args // { system = "x86_64-darwin"; });
      defaultPackage."x86_64-darwin" = self.packages."x86_64-darwin".nixpkgs-update;
      devShell."x86_64-darwin" = self.packages."x86_64-darwin".devShell;
    };
}
