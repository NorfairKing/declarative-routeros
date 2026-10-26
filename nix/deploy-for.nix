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
#   nix run .#deploy-<name>              applies the configuration
#   nix run .#deploy-<name>.download     reads the router into the record
#   nix run .#deploy-<name>.import-rest  finishes a deployment that stopped
#
# Reading the router is built from no configuration, which is what makes it the
# way back from a router the checks no longer answer for. The same action on the
# deployment itself knows where the halves are, so it only exists for a
# configuration that checked out.
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

  # Built before a command that writes to the router exists, and not referred to
  # by it: no deployment exists for a file RouterOS refused.
  vmtested = routeros-vmtest-check-for {
    inherit name chassis;
    configuration = "${checked}/configuration.rsc";
  };

  # One command per action, so what a stopped deployment sends you to is a
  # thing to run rather than flags to reassemble.
  commandFor = { suffix ? "", flags, description, afterChecks ? [ ], passthru ? { } }:
    let
      program = "deploy-${name}${suffix}";
    in
    runCommand program
      {
        inherit passthru;
        # Named in the derivation rather than used in the build, which is what
        # makes nix build them first: a check is something that has to have
        # passed, not something the command then has to carry around.
        requiredChecks = afterChecks;
        nativeBuildInputs = [ makeWrapper ];
        meta = {
          inherit description;
          mainProgram = program;
        };
      } ''
      makeWrapper ${lib.getExe declarative-routeros} "$out/bin/${program}" \
        --add-flags ${lib.escapeShellArg (lib.escapeShellArgs flags)}
    '';

  # Which router and as whom, which is all it takes to read one: no settings
  # file, no halves, nothing a check had to write first.
  downloadCommand = commandFor {
    suffix = "-download";
    flags = [ "download" "--into" record "--username" username "--port" (toString port) address ];
    description = "Read what ${name} says about itself into the record the checks read";
  };

  settings = writeText "${name}-router.json" (builtins.toJSON {
    inherit name username address port;
    prefix = "${checked}/prefix.rsc";
    rest = "${checked}/rest.rsc";
    checkedAgainst = export;
    recordInto = record;
    # A whole command rather than something to assemble: this is what a
    # deployment that found the router changed sends you to.
    downloadWith = lib.getExe downloadCommand;
  });
in
commandFor {
  flags = [ "router" "--settings" "${settings}" ];
  description = "Apply ${name}'s configuration, in the two halves that keep it reachable";
  afterChecks = [ vmtested ];
  passthru = {
    inherit checked vmtested;

    download = downloadCommand;

    import-rest = commandFor {
      suffix = "-import-rest";
      flags = [ "router" "--settings" "${settings}" "import-rest" ];
      description = "Import the second half onto ${name} as it is, without resetting it";
      afterChecks = [ vmtested ];
    };
  };
}
