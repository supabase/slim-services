{
  pkgs,
  src,
  version,
  hashes,
}:
let
  inherit (pkgs) lib;
  lines = lib.splitString "\n" (builtins.readFile (src + "/go.mod"));
  directive = lib.findFirst (line: lib.hasPrefix "toolchain go" line) null lines;
  goDirective = lib.findFirst (
    line: lib.hasPrefix "go " line
  ) (throw "Auth go.mod has no Go version") lines;
  declared =
    if directive != null then
      lib.removePrefix "toolchain go" directive
    else
      lib.removePrefix "go " goDirective;
  goVersion =
    if builtins.length (lib.splitString "." declared) == 2 then "${declared}.0" else declared;
  goOS = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux";
  goArch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  # Go's official compiler archive is fixed by the upstream go.mod directive.
  # Using it avoids both host toolchain downloads and upgrading old releases
  # whenever the repository's nixpkgs pin changes.
  goArchive = pkgs.fetchurl {
    url = "https://go.dev/dl/go${goVersion}.${goOS}-${goArch}.tar.gz";
    hash = hashes.go_toolchain_hash or lib.fakeHash;
  };
  go = pkgs.stdenvNoCC.mkDerivation {
    pname = "go-auth-toolchain";
    version = goVersion;
    src = goArchive;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p $out/share/go $out/bin
      cp -R . $out/share/go/
      ln -s $out/share/go/bin/go $out/bin/go
      ln -s $out/share/go/bin/gofmt $out/bin/gofmt
    '';
    passthru = {
      GOOS = goOS;
      GOARCH = goArch;
      CGO_ENABLED = "0";
    };
  };
  package = (pkgs.buildGoModule.override { inherit go; }) {
    pname = "auth";
    inherit src version;
    vendorHash = hashes.vendor_hash or lib.fakeHash;
    env.CGO_ENABLED = "0";
    subPackages = [ "." ];
    doCheck = false; # The release workflow exercises the real Auth/DB integration.
    ldflags = [
      "-s"
      "-w"
      "-X github.com/supabase/auth/internal/utilities.Version=${version}"
    ];
    postInstall = ''
      if [ -f $out/bin/gotrue ]; then mv $out/bin/gotrue $out/bin/auth; fi
      ln -s auth $out/bin/gotrue
    '';
  };
in
{
  runtime = package;
  probeOrder = [
    "go_toolchain_hash"
    "vendor_hash"
  ];
  dependencyProbes = {
    go_toolchain_hash = goArchive;
    vendor_hash = package.goModules;
  };
}
