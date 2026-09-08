{ lib
, runCommand
, makeWrapper
, writeText
, declarative-routeros
, routeros-checked-for
, routeros-vmtest-check-for
}:
# One router's deployment: the tool, told which router. Everything it does is in
# ../declarative-routeros/src/commands.
#
#   nix run .#deploy-<name>                 applies the configuration
#   nix run .#deploy-<name> -- download     reads the router into the record
#   nix run .#deploy-<name> -- import-rest  finishes a deployment that stopped
{ name
  # Not pre-checked: `checked` below is what checks it.
, configuration
  # A nix list, or a path to the JSON one.
, hosts
, chassis
  # A verbose export says which words the router accepts, whatever RouterOS it
  # is running, which no vm can promise.
, export
  # Where the deployment writes what the router says about itself afterwards,
  # relative to wherever it is run from.
, record
, address
, username
, port ? 22
}:
let
  # The checker writes no halves for a file it has anything to say about.
  checked = routeros-checked-for { inherit name configuration hosts chassis export; };

  # Depended on, not run: no deployment exists for a file RouterOS refused.
  vmtested = routeros-vmtest-check-for {
    inherit name chassis;
    configuration = "${checked}/configuration.rsc";
  };

  settings = writeText "${name}-router.json" (builtins.toJSON {
    inherit name username address port;
    prefix = "${checked}/prefix.rsc";
    rest = "${checked}/rest.rsc";
    checkedAgainst = export;
    recordInto = record;
  });
in
runCommand "deploy-${name}"
{
  nativeBuildInputs = [ makeWrapper ];
  meta = {
    description = "Apply ${name}'s configuration, in the two halves that keep it reachable";
    mainProgram = "deploy-${name}";
  };
  passthru = { inherit checked vmtested; };
} ''
  makeWrapper ${lib.getExe declarative-routeros} $out/bin/deploy-${name} \
    --add-flags ${lib.escapeShellArg "router --settings ${settings}"}
''
