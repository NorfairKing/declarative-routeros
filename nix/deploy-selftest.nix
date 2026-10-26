{ linkFarm
, routeros-deploy-for
}:
# What a deployment carries besides the deployment. The checks have examples of
# their own; this is about which of these commands exist when a check has
# something to say, because that is when somebody reaches for one.
let
  examples = ../examples;

  deploymentFor = configuration: routeros-deploy-for {
    name = "selftest";
    inherit configuration;
    hosts = examples + "/hosts.json";
    chassis = examples + "/chassis.json";
    export = examples + "/export.rsc";
    record = "selftest";
    address = "192.168.88.1";
    username = "admin";
  };

  # The checker refuses this file, so nothing built from it can be built. What
  # reads the router is not built from it, and that is the whole point: a
  # configuration nobody can deploy is the state you need to read a router in.
  refused = deploymentFor (examples + "/caught-by-check/unknown-verb.rsc");
in
linkFarm "routeros-deploy-selftest" [
  {
    name = "reads-a-router-whose-configuration-the-checker-refuses";
    path = refused.download;
  }
]
