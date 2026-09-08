{ lib
, runCommand
, writeShellApplication
, expect
, qemu
, coreutils
, chr
}:
# RouterOS is the only thing that parses RouterOS. Everything the chassis decides
# is decided here, so a chassis this image cannot stand in for is an evaluation
# error and not a message five minutes into a boot.
{ name
, configuration
, chassis
}:
let
  described = builtins.fromJSON (builtins.readFile chassis);

  # Served read-only by qemu's own tftp server, so the router imports this file
  # byte for byte with no host network involved.
  tftp = runCommand "vmtest-${name}-tftp" { } ''
    mkdir -p $out
    cp ${configuration} $out/configuration.rsc
  '';

  # Said out loud rather than refused, because there is no older CHR to boot.
  # What covers the gap is routeros-check --export, since the words in an export
  # are the words the router itself accepts.
  aboutTheVersion =
    if described.version == chr.version
    then "echo 'That router and this vm both run RouterOS ${chr.version}.'"
    else ''
      echo 'That router runs RouterOS ${described.version}. This vm runs ${chr.version}.'
      echo 'Those differ, so this vm can accept a file the router would refuse.'
    '';
  # RouterOS decides what a parameter means from what the hardware is, so another
  # architecture would answer for hardware nobody has.
in
assert lib.assertMsg (described.architectureName == chr.architecture)
  "vmtestFor: ${name} is ${described.architectureName}, and the only RouterOS here is ${chr.architecture}";
writeShellApplication {
  name = "vmtest-${name}";
  runtimeInputs = [ expect coreutils ];

  runtimeEnv = {
    VMTEST_INTERFACES = lib.concatStringsSep " " described.interfaces;
    VMTEST_SERIALS = toString described.serialPorts;
    VMTEST_QEMUDIR = qemu;
    VMTEST_TFTPDIR = tftp;
    VMTEST_MEMORY = "1024";
  };

  text = ''
    # The router writes to its disk, so it gets a copy of its own.
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    install -m 600 ${chr} "$work/disk.img"
    export VMTEST_DISK="$work/disk.img"

    # A port cannot be picked before the run: it has to be one that is free.
    export VMTEST_SSHPORT="''${VMTEST_SSHPORT:-0}"
    export VMTEST_HOLD="''${VMTEST_HOLD:-0}"

    echo 'Importing ${name} into RouterOS under qemu.'
    echo 'This boots a router and waits for it, so it takes minutes rather than seconds.'
    ${aboutTheVersion}
    exec expect -f ${../vmtest/vmtest.exp}
  '';

  meta.description = "Import ${name}'s configuration into a RouterOS router under qemu";
}
