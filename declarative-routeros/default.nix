{ rustPlatform
}:
rustPlatform.buildRustPackage {
  pname = "declarative-routeros";
  version = "0.0.0";

  src = ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };
}
