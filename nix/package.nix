# Builds only the b43 directory of the running kernel's source tree, with the
# patch applied, against that kernel's config, and installs the result into
# lib/modules/<version>/updates/ so it shadows the in-tree b43. Rebuilding
# after a patch change takes seconds, the kernel itself is untouched.
{
  lib,
  stdenv,
  kernel,
  kernelModuleMakeFlags,
  # CONFIG_B43_DEBUG for this module only: debugfs (/sys/kernel/debug/b43/
  # phyN/{mmio,shm}16{read,write}, restart, txstat ...) and b43dbg messages.
  debug ? false,
}:
stdenv.mkDerivation {
  pname = "b43-ht";
  version = kernel.version;
  src = kernel.src;
  unpackPhase = ''
    tar -xf $src --strip-components=1 --wildcards '*/drivers/net/wireless/broadcom/b43/*'
  '';
  # In the order of patches/series (comments and blank lines skipped)
  patches = map (name: ../patches + "/${name}") (
    builtins.filter (l: l != "" && builtins.substring 0 1 l != "#") (
      lib.splitString "\n" (builtins.readFile ../patches/series)
    )
  );
  nativeBuildInputs = kernel.moduleBuildDependencies;
  makeFlags =
    kernelModuleMakeFlags
    ++ [
      "-C"
      "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
      "M=$(PWD)/drivers/net/wireless/broadcom/b43"
    ]
    ++ lib.optionals debug [
      "CONFIG_B43_DEBUG=y"
      "KCFLAGS=-DCONFIG_B43_DEBUG=1"
    ];
  buildFlags = [ "modules" ];
  installPhase = ''
    install -Dm644 drivers/net/wireless/broadcom/b43/b43.ko \
      $out/lib/modules/${kernel.modDirVersion}/updates/b43.ko
  '';
  meta = {
    description = "b43 with 5 GHz and 802.11n on the BCM4331 HT-PHY";
    homepage = "https://github.com/Xerxes-2/b43-ht";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
