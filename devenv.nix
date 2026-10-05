{pkgs, ...}: {
  packages = with pkgs; [
    just
    selene
    stylua
  ];
  languages.lua.enable = true;
  languages.rust = {
    enable = true;
    channel = "stable";
  };
}
