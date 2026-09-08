{ lib
, runCommand
, writeText
, routeros-check
}:
{ name
, configuration
, hosts
, chassis
, export
}:
assert lib.assertMsg (chassis != null)
  "checkedFor: ${name} has no chassis, so nothing knows what hardware its configuration may name";
assert lib.assertMsg (export != null)
  "checkedFor: ${name} has no export, so nothing knows which words its RouterOS accepts";
runCommand "routeros-${name}" { } ''
  mkdir -p $out
  ${routeros-check}/bin/routeros-check \
    ${configuration} \
    ${if builtins.isList hosts then writeText "${name}-hosts.json" (builtins.toJSON hosts) else hosts} \
    --chassis ${chassis} \
    --export ${export} \
    --into $out
''
