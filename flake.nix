{
  description = "declarative-routeros";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-26.05";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    hopinion.url = "github:NorfairKing/hopinion";
    hopinion.flake = false;
  };

  outputs =
    { self
    , nixpkgs
    , pre-commit-hooks
    , hopinion
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

      # A nixpkgs of its own, because its overlay overrides haskellPackages and
      # nothing it does should change what gets built.
      hopinionPkgs = import nixpkgs {
        inherit system;
        overlays = [
          self.overlays.${system}
          (import (hopinion + "/nix/overlay.nix"))
        ];
      };
    in
    {
      overlays.${system} = import ./nix/overlay.nix;
      packages.${system} = {
        default = pkgs.declarative-routeros;

        inherit (pkgs.declarative-routeros) routeros-check;
        routeros-vmtest-selftest = pkgs.declarative-routeros.vmtestSelftest;
      };

      apps.${system}.update-chr-images = {
        type = "app";
        program = "${pkgs.declarative-routeros.routeros-check}/bin/update-chr-images";
      };

      checks.${system} = {
        release = self.packages.${system}.default;
        shell = self.devShells.${system}.default;

        inherit (pkgs.declarative-routeros) routeros-check;

        routeros-deploy-selftest = pkgs.declarative-routeros.deploySelftest;

        # Which RouterOS a vm test boots, decided from the record alone, so this
        # needs no image and no vm.
        chr-for-chassis =
          let
            nearest = pkgs.declarative-routeros.chrs.nearestIn [ "7.15" "7.15.1" "7.21" "7.25.1" ];
          in
          assert nearest "7.21" == "7.21";
          assert nearest "7.11beta4" == "7.15";
          assert nearest "7.15beta2" == "7.15";
          assert nearest "7.15.1" == "7.15.1";
          assert nearest "7.16" == "7.21";
          assert nearest "7.21rc1" == "7.21";
          assert nearest "7.26beta2" == "7.25.1";
          assert (pkgs.declarative-routeros.chrs.forChassis { version = "7.11beta4"; }).version == "7.21";
          assert (pkgs.declarative-routeros.chrs.forChassis { version = "7.21.3"; }).version == "7.21.3";
          pkgs.runCommand "chr-for-chassis" { } "touch $out";

        hopinion = hopinionPkgs.hopinion.makeHopinionCheck {
          src = ./.;
          packages = [ "routeros-check" ];
        };

        pre-commit = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixpkgs-fmt.enable = true;
            hpack.enable = true;
            ormolu.enable = true;
            deadnix.enable = true;
            statix.enable = true;
            # The dangerous functions list is vendored in ./.hlint.yaml, since
            # hlint cannot fetch one.
            hlint.enable = true;
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
        inherit (self.checks.${system}.pre-commit) shellHook;
      };
    };
}
