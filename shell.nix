# shell.nix
let
  pkgs = import <nixpkgs> { };

  # Use GHC 9.6.3 specifically for polysemy compatibility
  hsPkgs = pkgs.haskell.packages.ghc963;

  # Import test dependencies
  testDeps = import ./test-deps.nix { inherit pkgs; };

  # Create a Haskell environment with the packages we need
  ghc = hsPkgs.ghcWithPackages (ps: with ps; [
    cabal-install
    polysemy
    polysemy-plugin
    doctest
    aeson
    bytestring
    containers
    cryptonite
    memory
    mtl
    text
    time
    transformers
    with-utf8
    # Test dependencies
    hspec
    hspec-discover
    hspec-core
    QuickCheck
    async
  ]);

in
pkgs.mkShell {
  buildInputs = [
    ghc
    hsPkgs.cabal-install
    hsPkgs.haskell-language-server
    hsPkgs.doctest
    pkgs.ghcid
  ];

  shellHook = ''
    # Set up GHC environment
    export PATH="${ghc}/bin:${hsPkgs.cabal-install}/bin:$PATH"
    export GHC="${ghc}/bin/ghc"
    export GHC_PACKAGE_PATH="${ghc}/lib/ghc-9.6.3/package.conf.d"
    export HIE_BIOS_GHC="${ghc}/bin/ghc"
  '';
}
