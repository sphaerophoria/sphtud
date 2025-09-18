let
  pkgs = import <nixpkgs> { };
  unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/f73d4f0ad010966973bc81f51705cef63683c2f2.tar.gz") {};
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
