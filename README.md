# Declarative RouterOS (Mikrotik)

[![NixCI](https://staging.nix-ci.com/badge/gh:NorfairKing:declarative-routeros)](https://staging.nix-ci.com/gh:NorfairKing:declarative-routeros)

Declarative configuration management for routers running RouterOS like Mikrotik routers.

## Installation

### With cargo

``` console
git clone https://github.com/NorfairKing/declarative-routeros.git
cd declarative-routeros/declarative-routeros
cargo build --release
```

### With nix flakes

There is a `flake.nix` that will let you incorporate this tool into your system, but you can also run this command:

```
nix run github:NorfairKing/declarative-routeros
```

## How to use


1. Figure out your router's IP address.
   Let's say it is `192.168.100.1`.

   Every command that talks to it asks for the password on the terminal, or
   takes it from `ROUTEROS_SSH_PASSWORD` when there is no terminal to ask on.

1. Download what the router is and what it is set to:

   ``` console
   declarative-routeros download --username admin 192.168.100.1 --into .
   ```

   That writes `export.rsc`, `export-verbose.rsc` and `chassis.json`, which
   are a record of the router and not a configuration to apply:
   `export.rsc` is what it is set to, `chassis.json` is what it is made of, and
   `export-verbose.rsc` is the same configuration with every default spelled
   out, which is unreadable but is the router's own account of which words it
   accepts. Keep all three and commit them. The checks read them the way a
   golden file is read.
1. Copy `export.rsc` to `configuration.rsc` and make your changes there. That
   file is the one that gets applied, and it stays separate from the record
   above so that a check has something to check against.
1. Apply your changes. `reset-into` resets the router into the whole file in
   one go, which is the simple way and the one that can leave you locked out if
   the file is wrong.

   ``` console
   declarative-routeros reset-into --username admin 192.168.100.1 configuration.rsc
   ```

   The next section is the way that cannot: it splits the file in two and only
   ever pairs the reset with the half that gets you back in.

## Deploying from your own flake

`deployFor` builds a command that deploys one router. Both checks run when it
is built, so the command does not exist for a configuration that would not
apply:

``` nix
{
  inputs.declarative-routeros.url = "github:NorfairKing/declarative-routeros";

  outputs = { declarative-routeros, ... }:
    let
      system = "x86_64-linux";
      routeros = declarative-routeros.packages.${system}.default;
    in
    {
      packages.${system}.deploy-router = routeros.deployFor {
        name = "router";
        address = "192.168.88.1";
        username = "admin";

        configuration = ./router/configuration.rsc;

        # What else is supposed to be on this network
        hosts = [
          {
            name = "server";
            address = "192.168.88.10";
            mac = "aa:aa:aa:aa:aa:aa";
            forwards = [{ protocol = "tcp"; port = "443"; }];
          }
        ];

        # From `declarative-routeros download`.
        chassis = ./router/chassis.json;
        export = ./router/export-verbose.rsc;

        # Where the deployment writes all three again afterwards, relative to
        # wherever it is run.
        record = "router";
      };
    };
}
```

``` console
nix build .#deploy-router   # runs the checks
nix run .#deploy-router     # deploys
```

If a deployment stops half way, the same command has the two halves of it:

``` console
nix run .#deploy-router -- download     # reads the router into the record
nix run .#deploy-router -- import-rest  # imports the second half, no reset
```

### Hacking

Run `nix develop` or `direnv allow` to get a development shell.
Get `nix flake check` to pass before you make a PR.
