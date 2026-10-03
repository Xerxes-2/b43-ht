# NixOS module: replaces the in-tree b43 with the patched one and turns the
# HT-PHY features on.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.b43-ht;
in
{
  options.hardware.b43-ht = {
    enable = lib.mkEnableOption "the patched b43 driver for the BCM4331 HT-PHY";

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Build with CONFIG_B43_DEBUG (debugfs, debug messages).";
    };

    band5GHz = lib.mkOption {
      type = lib.types.enum [
        "off"
        "rx-only"
        "full"
      ];
      default = "full";
      description = "5 GHz support (module parameter htphy_5ghz = 0/1/2).";
    };

    ht = lib.mkOption {
      type = lib.types.ints.between 0 3;
      default = 3;
      description = ''
        802.11n (module parameter htphy_11n): 0 = off, 1 = HT rates and
        RX A-MPDU, 2 = also TX A-MPDU, 3 = also 40 MHz on 5 GHz.
      '';
    };

    extraOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "htphy_rxcal=0" ];
      description = "Further b43 module parameters.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.extraModulePackages = [
      (config.boot.kernelPackages.callPackage ./package.nix { inherit (cfg) debug; })
    ];
    # Microcode 666.2. Unfree: allow "b43-firmware".
    hardware.firmware = [ pkgs.b43Firmware_5_1_138 ];
    boot.extraModprobeConfig =
      let
        band = {
          off = 0;
          rx-only = 1;
          full = 2;
        };
      in
      "options b43 ${
        lib.concatStringsSep " " (
          [
            "htphy_5ghz=${toString band.${cfg.band5GHz}}"
            "htphy_11n=${toString cfg.ht}"
          ]
          ++ cfg.extraOptions
        )
      }";
    # mac80211 can't change the MAC address of a running interface, so
    # NetworkManager takes it down and up around every scan with a random
    # address; wpa_supplicant scans racing that fail and cost ~5 s per
    # connection.
    networking.networkmanager.wifi.scanRandMacAddress = lib.mkDefault false;
  };
}
