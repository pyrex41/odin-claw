package main

import "core:testing"

// Tests for runtime functionality

@test
test_native_run :: proc(t: ^testing.T) {
    rt := create_native_runtime()
    defer rt.vtable.deinit(&rt)
    res, err := rt.vtable.run(&rt, "echo", {"hello"}, {}, {}, {})
    testing.expect(t, err == .None, "Expected no error")
    testing.expect(t, res.exit_code == 0, "Expected exit code 0")
}