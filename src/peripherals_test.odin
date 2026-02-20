package main

import "core:testing"

// Tests for peripherals functionality

@test
test_detect_peripherals_no_crash :: proc(t: ^testing.T) {
    peripherals := detect_peripherals()
    defer deinit_peripherals(peripherals)
    // On non-Linux, should be empty. On Linux, may have devices.
    // Main assertion: no crash.
    testing.expect(t, true, "detect_peripherals should not crash")
}

@test
test_serial_not_supported :: proc(t: ^testing.T) {
    p := init_serial_peripheral("/dev/ttyUSB0", 9600)
    defer p.vtable.deinit(p.ptr)

    when ODIN_OS != .Linux {
        err := p.vtable.detect(p.ptr)
        testing.expect(t, err == .Not_Supported, "Should return Not_Supported on non-Linux")

        _, read_err := p.vtable.read(p.ptr, nil)
        testing.expect(t, read_err == .Not_Supported, "Read should return Not_Supported")

        write_err := p.vtable.write(p.ptr, nil)
        testing.expect(t, write_err == .Not_Supported, "Write should return Not_Supported")
    }
}