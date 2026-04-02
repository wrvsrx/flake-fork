{
  outputs =
    inputs:
    let
      systems = [ "x86_64-linux" ];
    in
    {
      devShells = builtins.listToAttrs (
        builtins.map (system: {
          name = system;
          value =
            let
              pkgs = import ./externals/nixpkgs { inherit system; };
            in
            {
              default = pkgs.mkShell { nativeBuildInputs = [ pkgs.lean4 ]; };
            };
        }) systems
      );
    };
}
