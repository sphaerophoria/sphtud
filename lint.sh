#!/usr/bin/env bash

set -ex

zig fmt src build.zig --check

zig build
./zig-out/bin/sphtud_test
