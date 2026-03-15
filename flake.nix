{
  description = "declarative-routeros";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-25.11";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      pre-commit-hooks,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [
            self.overlays.default
          ];
        };
    in
    {
      overlays.default = import ./nix/overlay.nix;
      packages = forAllSystems (system: {
        default = (pkgsFor system).declarative-routeros;
      });
      checks = forAllSystems (system: {
        release = self.packages.${system}.default;
        shell = self.devShells.${system}.default;
        pre-commit = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixpkgs-fmt.enable = true;
          };
        };
      });
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            name = "declarative-routeros-shell";
            buildInputs =
              with pkgs;
              [
                cargo
                clippy
                openssl
                pkg-config
                rust-analyzer
                rustfmt
                rustc
              ]
              ++ self.checks.${system}.pre-commit.enabledPackages;
            shellHook = self.checks.${system}.pre-commit.shellHook;
          };
        }
      );
    };
}
