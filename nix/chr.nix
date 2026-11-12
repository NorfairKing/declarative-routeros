{ lib
, fetchurl
, runCommand
, unzip
}:
# MikroTik's Cloud Hosted Router: the only build of RouterOS that boots under
# qemu. Unlicensed it runs at 1Mbit per interface, plenty to import a file.
let
  imageOf = version: { url, sha256 }:
    let
      name = lib.removeSuffix ".zip" (baseNameOf url);
    in
    runCommand name
      {
        nativeBuildInputs = [ unzip ];
        passthru = {
          inherit version;
          architecture = "arm64";
        };
      } ''
      unzip ${fetchurl { inherit url sha256; }}
      mv ${name} $out
    '';

  # Every arm64 image MikroTik builds, as `nix run .#update-chr-images` last
  # found them.
  images = builtins.fromJSON (builtins.readFile ./chr-images.json);

  # RouterOS puts a beta and a release candidate before the release they lead
  # up to, where compareVersions would put them after it.
  comparable = builtins.replaceStrings [ "beta" "rc" ] [ "pre0." "pre1." ];
  compare = a: b: builtins.compareVersions (comparable a) (comparable b);

  # The router's own version when there is an image of it. Otherwise the
  # earliest version after it, which has every word the router has, and past
  # the newest, the newest.
  nearestIn = versions: version:
    let
      sorted = lib.sort (a: b: compare a b < 0) versions;
      notBefore = lib.filter (candidate: compare candidate version >= 0) sorted;
    in
    if notBefore != [ ] then lib.head notBefore else lib.last sorted;

  # Older arm64 images time out partway through importing a real configuration
  # under emulation ("action timed out"), then drop the console back to its
  # login prompt: tried with 7.15, 7.17, 7.19 and 7.20, against 7.21 which
  # imports the same file cleanly. MikroTik builds them, but this vm cannot use
  # them.
  oldestUsable = "7.21";
  usable = lib.filter (version: compare version oldestUsable >= 0) (lib.attrNames images);

  imageNearest = version:
    let
      chosen = nearestIn usable version;
    in
    imageOf chosen images.${chosen};
in
{
  inherit nearestIn;

  # For whatever has no router to be near.
  default = imageNearest (lib.last (lib.sort (a: b: compare a b < 0) usable));

  # A vm running another version compiles some files differently, so the
  # nearest image to the router's own.
  forChassis = described: imageNearest described.version;
}
