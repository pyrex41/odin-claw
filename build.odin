package main

import "core:build"

main :: proc() {
    // Basic build configuration
    config := build.Config{
        name = "nullclaw",
        src_path = "src",
        out_path = "nullclaw",
        kind = .Executable,
        optimization = .Speed,  // For small binary
    }

    build.build(config)
}