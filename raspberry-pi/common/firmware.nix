# Firmware-partition install for Raspberry Pi.
#
# Stages the files the Pi needs before Linux starts onto the firmware partition
# (default /boot/firmware): GPU boot code (bootcode.bin, start*.elf, fixup*.dat),
# vendor device trees and overlays, the rendered config.txt, and either U-Boot
# or the kernel itself. By default boards still use
# boot.loader.generic-extlinux-compatible (U-Boot reads extlinux.conf). With
# kernelBoot.enable the firmware loads the kernel, initrd and cmdline.txt
# directly and there is no second-stage loader. The files are staged either at
# SD-image build time (sdImage.populateFirmwareCommands, wired automatically) or
# on a running system (the opt-in activation script).
#
# DTB/overlay copy adapted from nvmd/nixos-raspberrypi (MIT).

{
  lib,
  config,
  options,
  pkgs,
  ...
}:

let
  cfg = config.hardware.raspberry-pi.firmware;

  # install-rpi-firmware <target-dir> <system-toplevel>
  # The toplevel is only read with kernelBoot.enable.
  # Idempotent: copies via temp file + rename, and prunes stale DTBs/overlays.
  mkInstallScript =
    scriptPkgs:
    scriptPkgs.writeShellApplication {
      name = "install-rpi-firmware";
      runtimeInputs = [ scriptPkgs.coreutils ];
      text = ''
        target="$1"
        toplevel="''${2:-}"
        shopt -s nullglob

        firmwareBoot=${cfg.package}/share/raspberrypi/boot
        ${
          if cfg.useGenerationDeviceTree then
            ''
              # Prefer the booted generation's device trees over the vendor ones.
              dtbSrc=/run/current-system/dtbs
              [ -d "$dtbSrc" ] || dtbSrc=$firmwareBoot
            ''
          else
            ''
              dtbSrc=$firmwareBoot
            ''
        }

        mkdir -p "$target/overlays"

        # Copy via a temp file then rename so an interrupted run can't leave a
        # half-written file behind. The firmware partition is FAT, so the rename
        # isn't truly atomic, but it still beats a partial copy when the
        # activation script rewrites the partition on a live system.
        copyForced() {
          cp "$1" "$2.tmp"
          mv "$2.tmp" "$2"
        }

        # Track every file we copy this run, keyed by destination path, so the
        # prune step below can delete stale device trees / overlays left behind
        # by a previous generation.
        declare -A kept

        echo "rpi-firmware: copying device trees from $dtbSrc"
        for dtb in "$dtbSrc"/*.dtb "$dtbSrc"/broadcom/*.dtb; do
          dst="$target/$(basename "$dtb")"
          copyForced "$dtb" "$dst"
          kept[$dst]=1
        done

        # hardware.raspberry-pi.configtxt.deviceTreeOverlays entries are
        # matched by filename against the vendor .dtbo set the Raspberry Pi
        # firmware ships, regardless of whether the *base* dtb above came
        # from the generation or from firmwareBoot. Stage those
        # unconditionally so config.txt's "dtoverlay=" lines have a target
        # to apply, even when useGenerationDeviceTree = true.
        if [ -d "$firmwareBoot/overlays" ]; then
          for ovr in "$firmwareBoot"/overlays/*; do
            dst="$target/overlays/$(basename "$ovr")"
            copyForced "$ovr" "$dst"
            kept[$dst]=1
          done
        fi

        # When useGenerationDeviceTree also produced its own overlays
        # (built via hardware.deviceTree.overlays), stage those too,
        # letting them take precedence over same-named vendor overlays.
        if [ "$dtbSrc" != "$firmwareBoot" ] && [ -d "$dtbSrc/overlays" ]; then
          for ovr in "$dtbSrc"/overlays/*; do
           dst="$target/overlays/$(basename "$ovr")"
            copyForced "$ovr" "$dst"
            kept[$dst]=1
          done
        fi


        # Prune stale device trees / overlays.
        for fn in "$target"/*.dtb "$target"/overlays/*; do
          if [ "''${kept[$fn]:-}" != 1 ]; then
            rm -v -- "$fn"
          fi
        done

        echo "rpi-firmware: copying GPU boot code"
        for src in "$firmwareBoot"/bootcode.bin "$firmwareBoot"/start*.elf "$firmwareBoot"/fixup*.dat; do
          copyForced "$src" "$target/$(basename "$src")"
        done

        ${lib.optionalString cfg.uboot.enable ''
          echo "rpi-firmware: copying U-Boot"
          copyForced ${cfg.uboot.package}/u-boot.bin "$target/u-boot.bin"
        ''}

        ${lib.optionalString cfg.kernelBoot.enable ''
          if [ -z "$toplevel" ]; then
            echo "rpi-firmware: kernelBoot needs the system toplevel as second argument" >&2
            exit 1
          fi
          echo "rpi-firmware: copying kernel, initrd and cmdline.txt from $toplevel"
          copyForced "$toplevel/kernel" "$target/kernel.img"
          copyForced "$toplevel/initrd" "$target/initrd"
          # One line, as the firmware expects. The vendor DTB's /chosen/bootargs
          # are merged in by the firmware ahead of these.
          echo "$(cat "$toplevel/kernel-params") init=$(readlink -f "$toplevel")/init" > "$target/cmdline.txt.tmp"
          mv "$target/cmdline.txt.tmp" "$target/cmdline.txt"
        ''}

        echo "rpi-firmware: copying config.txt"
        copyForced ${config.hardware.raspberry-pi.configtxt.file} "$target/config.txt"

        echo "rpi-firmware: done ($target)"
      '';
    };

  # Target tools for activation, build tools for images.
  installScript = mkInstallScript pkgs;
  imageInstallScript = mkInstallScript pkgs.buildPackages;
in
{
  options.hardware.raspberry-pi.firmware = {
    enable = lib.mkEnableOption ''
      installation of the Raspberry Pi firmware partition on a running system.

      An activation script repopulates {option}`hardware.raspberry-pi.firmware.path`
      on every system switch
    '';

    path = lib.mkOption {
      type = lib.types.str;
      default = "/boot/firmware";
      description = ''
        Mount point of the Raspberry Pi firmware (FAT) partition.

        `/boot/firmware` matches the NixOS aarch64 SD-image layout, and most
        configurations should leave it there. The activation script writes here
        only when it is a mounted partition (checked with `mountpoint`);
        otherwise it logs a warning and skips.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.raspberrypifw;
      defaultText = lib.literalExpression "pkgs.raspberrypifw";
      description = ''
        Package providing the Raspberry Pi GPU boot code, vendor device trees,
        and overlays under `''${package}/share/raspberrypi/boot`.
      '';
    };

    uboot = {
      enable = lib.mkEnableOption ''
        chainloading U-Boot from the Raspberry Pi firmware.

        Copies `u-boot.bin` from
        {option}`hardware.raspberry-pi.firmware.uboot.package` to the firmware
        partition and points `config.txt`'s `kernel` at it, so the GPU firmware
        loads U-Boot, which then reads `extlinux.conf`
      '';

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.ubootRaspberryPiAarch64;
        defaultText = lib.literalExpression "pkgs.ubootRaspberryPiAarch64";
        description = ''
          U-Boot package whose `u-boot.bin` is copied to the firmware
          partition when {option}`hardware.raspberry-pi.firmware.uboot.enable`
          is enabled.

          The default, nixpkgs' `pkgs.ubootRaspberryPiAarch64`, covers the
          64-bit boards (Pi 3/4/5). For a 32-bit board, override this with the
          matching U-Boot package.
        '';
      };
    };

    kernelBoot.enable = lib.mkEnableOption ''
      booting Linux directly from the Raspberry Pi firmware, without U-Boot.

      The kernel, initrd and a `cmdline.txt` for the system are copied to the
      firmware partition and `config.txt` points the firmware at them. The
      firmware hands its own device tree, with `config.txt` overlays applied,
      straight to the kernel.

      Only one system is installed, there is no boot menu and no rollback:
      `generic-extlinux-compatible` is disabled and every install replaces the
      previous kernel. Suited to images that are reflashed rather than
      upgraded in place. Mutually exclusive with
      {option}`hardware.raspberry-pi.firmware.uboot.enable`
    '';

    useGenerationDeviceTree = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Copy device trees from the booted NixOS generation
        (`/run/current-system/dtbs`) instead of the vendor firmware package.
        Irrelevant when generating an SD image.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.uboot.enable {
      # Chainload U-Boot: the GPU firmware loads u-boot.bin, which then reads
      # extlinux.conf. mkDefault so an explicit kernel setting still wins.
      hardware.raspberry-pi.configtxt.settings.all = {
        kernel = lib.mkDefault "u-boot.bin";
        # Default U-Boot is 64-bit, but the firmware loads kernel= in 32-bit
        # mode unless arm_64bit=1.
        arm_64bit = lib.mkDefault pkgs.stdenv.hostPlatform.isAarch64;
      };

      # The GPU firmware merges config.txt dtoverlays into the DTB it hands to
      # U-Boot. The default (true) adds an FDTDIR line to extlinux.conf, so
      # U-Boot reloads bare dtbs and drops the overlays.
      boot.loader.generic-extlinux-compatible.useGenerationDeviceTree = lib.mkDefault false;
    })
    (lib.mkIf cfg.kernelBoot.enable {
      assertions = [
        {
          assertion = !cfg.uboot.enable;
          message = "hardware.raspberry-pi.firmware.kernelBoot.enable and uboot.enable are mutually exclusive.";
        }
        {
          assertion = !config.boot.loader.generic-extlinux-compatible.enable;
          message = ''
            hardware.raspberry-pi.firmware.kernelBoot.enable boots without U-Boot, so
            boot.loader.generic-extlinux-compatible.enable must stay false.
          '';
        }
      ];

      hardware.raspberry-pi.configtxt = {
        settings.all = {
          kernel = lib.mkDefault "kernel.img";
          # The firmware loads kernel= in 32-bit mode unless arm_64bit=1.
          arm_64bit = lib.mkDefault pkgs.stdenv.hostPlatform.isAarch64;
        };
        # Not key=value syntax, so it can't go through settings.
        extraConfig = ''
          initramfs initrd followkernel
        '';
      };

      # Overrides the board profiles' mkDefault. nixpkgs' sd-image-aarch64.nix
      # sets it to true and runs the extlinux builder; build images from
      # sd-image.nix instead.
      boot.loader.generic-extlinux-compatible.enable = false;

      # nixos-rebuild boot/switch: rewrite the kernel on the firmware partition.
      system.build.installBootLoader = pkgs.writeShellScript "install-rpi-kernelboot" ''
        if ! ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg cfg.path}; then
          echo "rpi-firmware: ${cfg.path} is not mounted, cannot install the kernel" >&2
          exit 1
        fi
        exec ${lib.getExe installScript} ${lib.escapeShellArg cfg.path} "$1"
      '';
      system.boot.loader.id = "raspberrypi-kernelboot";
    })
    # Stage the firmware partition at SD-image build time, only when an
    # sd-image module is imported. mkForce so we override (not merge with)
    # sd-image-aarch64.nix, which also sets this and would clobber config.txt.
    (lib.optionalAttrs (options ? sdImage) {
      sdImage.populateFirmwareCommands = lib.mkForce "${lib.getExe imageInstallScript} ./firmware ${config.system.build.toplevel}\n";
    })
    # The root partition's /boot stays empty; there is no extlinux.conf. The
    # kernel and initrd live on the firmware partition, so the 30 MiB default
    # is too small.
    (lib.optionalAttrs (options ? sdImage) (
      lib.mkIf cfg.kernelBoot.enable {
        sdImage.populateRootCommands = lib.mkForce ''
          mkdir -p ./files/boot
        '';
        sdImage.firmwareSize = lib.mkDefault 256;
      }
    ))
    (lib.mkIf cfg.enable {
      system.activationScripts.raspberry-pi-firmware = lib.stringAfter [ "specialfs" ] ''
        if mountpoint -q ${lib.escapeShellArg cfg.path}; then
          ${lib.getExe installScript} ${lib.escapeShellArg cfg.path} "$systemConfig"
        else
          echo "rpi-firmware: ${cfg.path} is not a mounted partition, skipping firmware install" >&2
        fi
      '';
    })
  ];
}
