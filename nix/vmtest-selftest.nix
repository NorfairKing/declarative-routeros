{ lib
, linkFarm
, callPackage
, declarative-routeros
, routeros-vmtest-for
, routeros-vmtest-check-for
, routeros-vmtest-refusal-for
, routeros-checked-for
}:
# One derivation per example, so nix runs them at once, an example that has not
# changed is not booted again, and a failure has a log of its own.
let
  examples = ../examples;
  chassis = ../examples/chassis.json;
  hosts = ../examples/hosts.json;
  export = ../examples/export.rsc;

  scriptsIn = subdir:
    lib.filter (lib.hasSuffix ".rsc")
      (builtins.attrNames (builtins.readDir (examples + "/${subdir}")));

  stem = lib.removeSuffix ".rsc";

  imports = script: {
    name = "imports/${stem script}";
    path = routeros-vmtest-check-for {
      name = stem script;
      configuration = examples + "/valid/${script}";
      inherit chassis;
    };
  };

  refuses = script: {
    name = "refuses/${stem script}";
    path = routeros-vmtest-refusal-for {
      name = stem script;
      configuration = examples + "/caught-by-vmtest/${script}";
      reason = examples + "/caught-by-vmtest/${stem script}.expected";
      inherit chassis;
    };
  };

  # An example the cheap check catches has stopped being one only a router can
  # catch.
  survivesTheCheapCheck = script: {
    name = "not-caught-by-the-cheap-check/${stem script}";
    path = routeros-checked-for {
      name = stem script;
      configuration = examples + "/caught-by-vmtest/${script}";
      inherit hosts chassis export;
    };
  };

  halvesOf = script: {
    name = stem script;
    path = routeros-checked-for {
      name = stem script;
      configuration = examples + "/deployable/${script}";
      inherit hosts chassis export;
    };
  };

  # The one part that is not per-example: it drives a router it holds open over
  # ssh, and what it asserts is what the tool wrote afterwards.
  tool = callPackage ../routeros-check {
    suite = "routeros-check-vmtest";

    vmrouter = lib.getExe (routeros-vmtest-for {
      name = "held";
      # Never imported in this mode, and there has to be one.
      configuration = examples + "/valid/minimal.rsc";
      inherit chassis;
    });

    checked = linkFarm "routeros-checked" (map halvesOf (scriptsIn "deployable"));

    tool = declarative-routeros;
  };
in
linkFarm "routeros-vmtest-selftest" (
  map imports (scriptsIn "valid")
  ++ map refuses (scriptsIn "caught-by-vmtest")
  ++ map survivesTheCheapCheck (scriptsIn "caught-by-vmtest")
  ++ [{ name = "tool"; path = tool; }]
)
