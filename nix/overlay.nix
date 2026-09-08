final: prev: {
  # In the package set rather than beside it, because what the compiler wrote
  # down about this package is only reachable from the set that built it.
  haskellPackages = prev.haskellPackages.override (old: {
    overrides = final.lib.composeExtensions (old.overrides or (_: _: { }))
      (hself: hsuper: {
        # Marked broken in nixpkgs; only its bounds are stale.
        diagnose = final.haskell.lib.compose.markUnbroken
          (final.haskell.lib.compose.doJailbreak hsuper.diagnose);

        routeros-check = hself.callCabal2nix "routeros-check" ../routeros-check { };
      });
  });

  declarative-routeros =
    let
      tool = final.callPackage ../declarative-routeros { };
      chr = final.callPackage ./chr.nix { };
      routeros-check = final.callPackage ../routeros-check { };
      vmtestFor = final.callPackage ./vmtest-for.nix { inherit chr; };
      vmtestCheckFor = final.callPackage ./vmtest-check-for.nix {
        routeros-vmtest-for = vmtestFor;
      };
      vmtestRefusalFor = final.callPackage ./vmtest-refusal-for.nix {
        routeros-vmtest-for = vmtestFor;
      };
      checkedFor = final.callPackage ./checked-for.nix { inherit routeros-check; };
    in
    tool.overrideAttrs (old: {
      passthru = (old.passthru or { }) // {
        inherit chr routeros-check checkedFor vmtestFor vmtestCheckFor vmtestRefusalFor;

        deployFor = final.callPackage ./deploy-for.nix {
          declarative-routeros = tool;
          routeros-checked-for = checkedFor;
          routeros-vmtest-check-for = vmtestCheckFor;
        };

        vmtestSelftest = final.callPackage ./vmtest-selftest.nix {
          declarative-routeros = tool;
          routeros-vmtest-for = vmtestFor;
          routeros-vmtest-check-for = vmtestCheckFor;
          routeros-vmtest-refusal-for = vmtestRefusalFor;
          routeros-checked-for = checkedFor;
        };
      };
    });
}
