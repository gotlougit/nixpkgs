{ lib
, stdenv
, hostPlatform
, engineVersion
, fetchzip
, autoPatchelfHook

, gtk3
}:

let
  hashes = (import ./hashes.nix).${engineVersion} or
    (throw "There are no known artifact hashes for Flutter engine version ${engineVersion}.");

  artifacts =
    {
      common = {
        flutter_patched_sdk = { archive = "flutter_patched_sdk.zip"; };
        flutter_patched_sdk_product = { archive = "flutter_patched_sdk_product.zip"; };
      };
      platform = {
        android =
          (lib.genAttrs
            [ "arm" "arm64" "x64" ]
            (arch:
              {
                base = [
                  { archive = "artifacts.zip"; }
                ];
                variants = lib.genAttrs [ "profile" "release" ]
                  (variant: [
                    { archive = "artifacts.zip"; }
                    { subdirectory = true; archive = "${lib.toLower hostPlatform.uname.system}-x64.zip"; }
                  ]);
              })) //
          {
            "x86" = {
              base = [
                { archive = "artifacts.zip"; }
              ];
              variants.jit-release = [
                { archive = "artifacts.zip"; }
              ];
            };
          };

        linux = lib.genAttrs
          [ "arm64" "x64" ]
          (arch:
            let
              linux-flutter-gtk = {
                archive = "linux-${arch}-flutter-gtk.zip";
                buildInputs = [ gtk3 ];
              };
            in
            {
              base = [
                ({ archive = "artifacts.zip"; } // lib.optionalAttrs (arch == "arm64") {
                  # For some reason, the arm64 artifacts are missing shader code in Flutter < 3.10.0.
                  postPatch = ''
                    if [ ! -d shader_lib ]; then
                      ln -s ${lib.findSingle
                        (pkg: lib.getName pkg == "flutter-artifact-linux-x64-artifacts")
                        (throw "Could not find the x64 artifact archive.")
                        (throw "Could not find the correct x64 artifact archive.")
                        artifactDerivations.platform.linux.x64.base
                      }/shader_lib .
                    fi
                  '';
                })
                { archive = "font-subset.zip"; }
                (linux-flutter-gtk // {
                  # https://github.com/flutter/flutter/commit/9d94a51b607600a39c14470c35c676eb3e30eed6
                  variant = "debug";
                })
              ];
              variants = lib.genAttrs [ "debug" "profile" "release" ] (variant: [
                linux-flutter-gtk
              ]);
            });
      };
    };

  mkArtifactDerivation = { platform ? null, variant ? null, subdirectory ? null, archive, ... }@args:
    let
      artifactDirectory = if platform == null then null else "${platform}${lib.optionalString (variant != null) "-${variant}"}";
      archiveBasename = lib.removeSuffix ".${(lib.last (lib.splitString "." archive))}" archive;
    in
    stdenv.mkDerivation ({
      pname = "flutter-artifact${lib.optionalString (platform != null) "-${artifactDirectory}"}-${archiveBasename}";
      version = engineVersion;

      src = fetchzip {
        url = "https://storage.googleapis.com/flutter_infra_release/flutter/${engineVersion}${lib.optionalString (platform != null) "/${artifactDirectory}"}/${archive}";
        stripRoot = false;
        hash = (if artifactDirectory == null then hashes else hashes.${artifactDirectory}).${archive};
      };

      nativeBuildInputs = [ autoPatchelfHook ];

      installPhase =
        let
          destination = "$out/${if subdirectory == true then archiveBasename else if subdirectory != null then subdirectory else "."}";
        in
        ''
          mkdir -p "${destination}"
          cp -r . "${destination}"
        '';
    } // args);

  artifactDerivations = {
    common = builtins.mapAttrs (name: mkArtifactDerivation) artifacts.common;
    platform =
      builtins.mapAttrs
        (os: architectures:
          builtins.mapAttrs
            (architecture: variants: {
              base = map
                (args: mkArtifactDerivation ({
                  platform = "${os}-${architecture}";
                } // args))
                variants.base;
              variants = builtins.mapAttrs
                (variant: variantArtifacts: map
                  (args: mkArtifactDerivation ({
                    platform = "${os}-${architecture}";
                    inherit variant;
                  } // args))
                  variantArtifacts)
                variants.variants;
            })
            architectures)
        artifacts.platform;
  };
in
artifactDerivations
