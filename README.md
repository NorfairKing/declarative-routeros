# Declarative RouterOS (Mikrotik)

Declarative configuration management for routers running RouterOS like Mikrotik routers.

## Installation

``` console
git clone https://github.com/NorfairKing/declarative-routeros.git
cd declarative-routeros/declarative-routeros
cargo build --release
```

## How to use


1. Figure out your router's IP address.
   Let's say it is `192.168.100.1`.

1. Download your current router configuration:

   ``` console
   declarative-routeros --username admin 192.168.100.1 download --output-file configuration.rsc
   ```

   Save this file somewhere as a backup.
1. Make your changes to `configuration.rsc` as desired.
1. Apply your changes:

   ``` console
   declarative-routeros --username admin 192.168.100.1 apply configuration.rsc
   ```

   The router will now restart with the new configuration as described in `configuration.rsc`.

## How it works

The `download` command will export the current configuration of the router to a file and download that file from the router to save locally.

The `apply` command will upload a configuration script to the router and then run this command to reset into it:

``` routeros
/system reset-configuration keep-users=yes no-defaults=yes run-after-reset=configuration.rsc
```

