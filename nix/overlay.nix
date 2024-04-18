final: prev: {
  declarative-routeros =
    let
      staticCheck = pkg:
        if final.stdenv.hostPlatform.isMusl
        then
          pkg.overrideAttrs
            (old: {
              postInstall = (old.postInstall or "") + ''
                for b in $out/bin/*
                do
                  if ldd "$b"
                  then
                    echo "ldd succeeded on $b, which may mean that it is not statically linked"
                    exit 1
                  fi
                done
              '';
            })
        else pkg;
    in
    staticCheck (final.callPackage ../declarative-routeros { });
}
