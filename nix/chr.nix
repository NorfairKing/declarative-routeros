{ fetchurl
, runCommand
, unzip
}:
# MikroTik's Cloud Hosted Router: the only build of RouterOS that boots under
# qemu. Unlicensed it runs at 1Mbit per interface, plenty to import a file.
let
  version = "7.21";
  architecture = "arm64";

  archive = fetchurl {
    url = "https://download.mikrotik.com/routeros/${version}/chr-${version}-${architecture}.img.zip";
    hash = "sha256-enbS6hPOqHpjhCuUAWV+UciG+3rvRSop0tIx4NTVehc=";
  };
in
runCommand "chr-${version}-${architecture}.img"
{
  nativeBuildInputs = [ unzip ];
  passthru = { inherit version architecture; };
} ''
  unzip ${archive}
  mv chr-${version}-${architecture}.img $out
''
