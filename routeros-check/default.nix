{ lib
, haskell
, haskellPackages
, expect
, qemu
  # The vm suite drives a router of its own, so it is a separate build and what
  # it drives is handed over here.
, suite ? "routeros-check-test"
, vmrouter ? null
, checked ? null
, tool ? null
}:
let
  underTest = vmrouter != null;
in
haskell.lib.compose.overrideCabal
  (old: {
    pname = if underTest then "routeros-check-vmtest" else "routeros-check";
    doCheck = true;
    testTargets = [ suite ];
    testToolDepends = (old.testToolDepends or [ ]) ++ lib.optionals underTest [ expect qemu tool ];
    preCheck = (old.preCheck or "") + ''
      export ROUTEROS_CHECK_EXAMPLES=${../examples}
      ${lib.optionalString underTest ''
        export ROUTEROS_VMROUTER=${vmrouter}
        export ROUTEROS_CHECKED=${checked}
      ''}
    '';
  })
  haskellPackages.routeros-check
