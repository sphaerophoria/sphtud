let
  pkgs = import <nixpkgs> { };
  unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/b12141ef619e0a9c1c84dc8c684040326f27cdcc.tar.gz") {};
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    unstable.zls
    unstable.zig
    valgrind
    gdb
    python3
    glfw
    libGL
    clang-tools
    wayland
    linuxPackages_latest.perf
    kcov
  ];

  LD_LIBRARY_PATH = "${pkgs.wayland}/lib";
}
