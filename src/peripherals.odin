package main

import "core:fmt"
import "core:testing"

Peripheral_Error :: enum {
    None,
    Not_Supported,
    Not_Found,
    Open_Failed,
    IO_Error,
}

Peripheral_VTable :: struct {
    detect: proc(ptr: rawptr) -> Peripheral_Error,
    read:   proc(ptr: rawptr, buf: []byte) -> (int, Peripheral_Error),
    write:  proc(ptr: rawptr, data: []byte) -> Peripheral_Error,
    deinit: proc(ptr: rawptr),
}

Peripheral :: struct {
    name:    string,
    path:    string,
    ptr:     rawptr,
    vtable:  ^Peripheral_VTable,
}

SerialPeripheral :: struct {
    device_path: string,
    baud_rate:   int,
    fd:          int,
}

init_serial_peripheral :: proc(device_path: string, baud_rate: int) -> Peripheral {
    sp := new(SerialPeripheral)
    sp.device_path = device_path
    sp.baud_rate = baud_rate
    sp.fd = -1
    return Peripheral{
        name = "serial",
        path = device_path,
        ptr = sp,
        vtable = &serial_vtable,
    }
}

serial_vtable := Peripheral_VTable{
    detect = serial_detect,
    read = serial_read,
    write = serial_write,
    deinit = serial_deinit,
}

serial_detect :: proc(ptr: rawptr) -> Peripheral_Error {
    // Serial device detection only works on Linux
    // On macOS/other platforms, return Not_Supported
    when ODIN_OS == .Linux {
        // On Linux, check if device file exists
        sp := (^SerialPeripheral)(ptr)
        // Would check os.exists(sp.device_path) but for now:
        return .Not_Found
    } else {
        return .Not_Supported
    }
}

serial_read :: proc(ptr: rawptr, buf: []byte) -> (int, Peripheral_Error) {
    when ODIN_OS == .Linux {
        sp := (^SerialPeripheral)(ptr)
        if sp.fd < 0 { return 0, .Open_Failed }
        return 0, .IO_Error
    } else {
        return 0, .Not_Supported
    }
}

serial_write :: proc(ptr: rawptr, data: []byte) -> Peripheral_Error {
    when ODIN_OS == .Linux {
        sp := (^SerialPeripheral)(ptr)
        if sp.fd < 0 { return .Open_Failed }
        return .IO_Error
    } else {
        return .Not_Supported
    }
}

serial_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

// detect_peripherals scans for available peripherals
// On non-Linux platforms, returns an empty slice
detect_peripherals :: proc() -> []Peripheral {
    peripherals := make([dynamic]Peripheral)

    when ODIN_OS == .Linux {
        // Scan /dev/ttyUSB* and /dev/ttyACM* for serial devices
        usb_paths := []string{
            "/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyUSB2", "/dev/ttyUSB3",
            "/dev/ttyACM0", "/dev/ttyACM1", "/dev/ttyACM2", "/dev/ttyACM3",
        }
        for path in usb_paths {
            p := init_serial_peripheral(path, 9600)
            if p.vtable.detect(p.ptr) == .None {
                append(&peripherals, p)
            } else {
                p.vtable.deinit(p.ptr)
            }
        }
    }

    return peripherals[:]
}

deinit_peripherals :: proc(peripherals: []Peripheral) {
    for p in peripherals {
        p.vtable.deinit(p.ptr)
    }
    delete(peripherals)
}


