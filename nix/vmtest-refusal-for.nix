{ runCommand
, routeros-vmtest-for
}:
# A configuration RouterOS is meant to refuse, and the reason it is meant to
# give. Refused for some other reason is an example that has stopped being
# about what it says it is about.
{ reason, ... }@args:
let
  vmtest = routeros-vmtest-for (builtins.removeAttrs args [ "reason" ]);
in
runCommand "routeros-vmtest-refuses-${args.name}" { } ''
  if ${vmtest}/bin/${vmtest.name} | tee $out; then
    echo "!!! it was accepted, which is the bug" >&2
    exit 1
  fi
  want="$(cat ${reason})"
  if ! grep -qF -- "$want" $out; then
    echo "!!! it was refused, but not for \"$want\"" >&2
    exit 1
  fi
''
