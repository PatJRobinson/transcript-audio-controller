{
  description = "Development shell for the transcript audio Neovim plugin";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = function:
        nixpkgs.lib.genAttrs systems (system: function {
          pkgs = import nixpkgs { inherit system; };
        });
    in
    {
      devShells = forAllSystems ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            git
            ripgrep
            neovim
            lua-language-server
            stylua
            luaPackages.luacheck
            mpv
            socat
            python3
            jq
          ];
        };
      });
    };
}
