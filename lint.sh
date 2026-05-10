#!/usr/bin/env bash

set -ex

zig fmt src build.zig --check

pushd src/sphmath/
zig build test
popd

zig build
./zig-out/bin/sphtud_test
