#!/bin/ksh

zig build -freference-trace=20 -Doptimize=ReleaseSafe && sudo cp ./zig-out/bin/resources /usr/local/bin/resources
