let
  pkgs = import <nixpkgs> { };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zls
    zig_0_14
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
