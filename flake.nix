{
  description = "gitomi development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    tree-sitter-zig = {
      url = "github:tree-sitter-grammars/tree-sitter-zig/6479aa13f32f701c383083d8b28360ebd682fb7d";
      flake = false;
    };
  };

  outputs =
    { nixpkgs, tree-sitter-zig, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forEachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_16
              pkgs.tree-sitter
            ];

            TREE_SITTER_PREFIX = "${pkgs.tree-sitter}";
            TREE_SITTER_ZIG_SRC = "${tree-sitter-zig}";
          };
        }
      );
    };
}
