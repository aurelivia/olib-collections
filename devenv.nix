{ pkgs, lib, config, inputs, ... }: let
  pkgs-unstable = import inputs.unstable { system = pkgs.stdenv.system; };
in {
  languages.zig.enable = true;
  languages.zig.package = pkgs-unstable.zig_0_15;
  languages.zig.zls.package = pkgs-unstable.zls_0_15;
}

