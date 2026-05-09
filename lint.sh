#!/usr/bin/env bash

set -ex

zig fmt src build.zig --check

pushd src/sphmath/
zig build test
popd

pushd src/sphutil/
zig build test
popd

pushd src/sphutil_noalloc/
zig build test
popd

pushd src/sphalloc/
zig build test
popd

pushd src/sphxml/
zig build test
popd

zig build
./zig-out/bin/sphtud_test
