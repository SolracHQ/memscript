default:
    @just --list

build:
    zig build

run *args:
    zig build
    sudo ./zig-out/bin/memscript {{args}}

test:
    zig build test

check: test

fmt:
    zig fmt build.zig src/*.zig

clean:
    rm -rf .zig-cache zig-out

rebuild: clean build