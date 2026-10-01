{pkgs, ...}: {
  packages = with pkgs; [
    gnumake
    just
    perl
    selene
    stylua
  ];
  languages.lua = {
    enable = true;
    lsp.enable = false;
  };
  languages.rust = {
    enable = true;
  };
}
