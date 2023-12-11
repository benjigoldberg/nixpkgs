{ lib
, stdenv
, fetchFromGitHub
, AppKit
, SkyLight
, testers
}:

let
  inherit (stdenv.hostPlatform) system;
  target = {
    "aarch64-darwin" = "arm64";
    "x86_64-darwin" = "x86";
  }.${system} or (throw "Unsupported system: ${system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "JankyBorders";
  version = "1.3.0";

  src = fetchFromGitHub {
    owner = "FelixKratz";
    repo = "JankyBorders";
    rev = "v${finalAttrs.version}";
    hash = stdenv.lib.fakeSha256;
  };

  buildInputs = [
    AppKit
    SkyLight
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp ./bin/borders $out/bin/borders

    runHook postInstall
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
    version = "borders-${finalAttrs.version}";
  };

  meta = {
    description = "JankyBorders is a lightweight tool designed to add colored borders to user windows on macOS 14.0+";
    homepage = "https://github.com/FelixKratz/JankyBorders";
    license = lib.licenses.gpl3;
    mainProgram = "borders";
    maintainers = with lib.maintainers; [ benjigoldberg ];
    platforms = lib.platforms.darwin;
  };
})
