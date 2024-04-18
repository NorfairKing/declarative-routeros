{ stdenv
, rustPlatform
  # System dependencies
, pkg-config
, openssl
}:
rustPlatform.buildRustPackage {
  pname = "declarative-routeros";
  version = "0.0.0";

  src = ./.;

  nativeBuildInputs = [
    pkg-config
  ];

  buildInputs = [
    (if stdenv.hostPlatform.isMusl
    then (openssl.override { static = true; })
    else openssl)
  ];

  cargoLock = {
    lockFile = ./Cargo.lock;
  };
}
