{
  description = "declarative-routeros";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-24.11";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
  };

  outputs =
    { self
    , nixpkgs
    , pre-commit-hooks
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [
          self.overlays.${system}
        ];
      };
      pkgsMusl = pkgs.pkgsMusl;
    in
    {
      overlays.${system} = import ./nix/overlay.nix;
      packages.${system} = {
        default = self.packages.${system}.dynamic;
        dynamic = pkgs.declarative-routeros;
        static = pkgsMusl.declarative-routeros;
      };
      checks.${system} = {
        release = self.packages.${system}.default;
        static = self.packages.${system}.static;
        dynamic = self.packages.${system}.dynamic;
        shell = self.devShells.${system}.default;
        pre-commit = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixpkgs-fmt.enable = true;
          };
        };
      };
      devShells.${system}.default = pkgs.mkShell {
        name = "declarative-routeros-shell";
        buildInputs = with pkgs; [
          cargo
          clippy
          openssl
          pkg-config
          rust-analyzer
          rustfmt
          rustc
        ] ++ self.checks.${system}.pre-commit.enabledPackages;
        shellHook = self.checks.${system}.pre-commit.shellHook;
      };
    };
}
