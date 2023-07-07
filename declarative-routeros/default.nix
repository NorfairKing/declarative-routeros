{ rustPlatform
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
    openssl
  ];

  cargoLock = {
    lockFile = ./Cargo.lock;
  };
}
