{ runCommand
, routeros-vmtest-for
}:
# The vm test as something that has to have passed, not something somebody ran.
args:
let
  vmtest = routeros-vmtest-for args;
in
runCommand "routeros-vmtest-${args.name}" { } ''
  ${vmtest}/bin/${vmtest.name} | tee $out
''
