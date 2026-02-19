package main

import "core:os"
import "core:strings"
import "core:fmt"
import "core:testing"

foreign {
    system :: proc "c" (command: cstring) -> i32 ---
    chdir :: proc "c" (path: cstring) -> i32 ---
}

// Runtime interface using vtable
Runtime_VTable :: struct {
    run: proc(self: ^Runtime, command: string, args: []string, env: map[string]string, limits: Runtime_Limits, path_control: Path_Control) -> (Runtime_Result, Runtime_Error),
    deinit: proc(self: ^Runtime),
}

Runtime :: struct {
    vtable: ^Runtime_VTable,
    data: rawptr,
}

// Result of execution
Runtime_Result :: struct {
    exit_code: int,
}

// Runtime errors
Runtime_Error :: enum {
    None,
    Exec_Failed,
    Timeout,
    Resource_Limit_Exceeded,
    Path_Denied,
}

// Resource limits
Runtime_Limits :: struct {
    memory_mb: int, // 0 for no limit
    cpu_seconds: int, // 0 for no limit
    disk_mb: int, // 0 for no limit
}

// Path control
Path_Control :: struct {
    allowed_paths: []string,
    chroot: string, // empty for no chroot
}

// Native runtime implementation
Native_Runtime :: struct {
    // No specific state needed
}

native_vtable: Runtime_VTable = {
    run = native_run,
    deinit = native_deinit,
}

create_native_runtime :: proc() -> Runtime {
    nr := new(Native_Runtime)
    return Runtime {
        vtable = &native_vtable,
        data = nr,
    }
}

native_run :: proc(self: ^Runtime, command: string, args: []string, env: map[string]string, limits: Runtime_Limits, path_control: Path_Control) -> (Runtime_Result, Runtime_Error) {
    // Check allowed paths
    if len(path_control.allowed_paths) > 0 {
        allowed := false
        for p in path_control.allowed_paths {
            if strings.has_prefix(command, p) {
                allowed = true
                break
            }
        }
        if !allowed {
            return {}, .Path_Denied
        }
    }
    // Set chroot if specified
    if path_control.chroot != "" {
        c_path := strings.clone_to_cstring(path_control.chroot)
        defer delete(c_path)
        if chdir(c_path) != 0 {
            return {}, .Path_Denied
        }
    }
    // TODO: Implement resource limits using syscall
    // Build command string
    cmd_str := command
    if len(args) > 0 {
        cmd_str = strings.concatenate({cmd_str, " ", strings.join(args, " ")})
    }
    // Execute (simple, no env handling yet)
    c_cmd := strings.clone_to_cstring(cmd_str)
    defer delete(c_cmd)
    exit_code := system(c_cmd)
    return Runtime_Result{int(exit_code)}, .None
}

native_deinit :: proc(self: ^Runtime) {
    free(self.data)
}

// Tests
@test
test_native_run :: proc(t: ^testing.T) {
    rt := create_native_runtime()
    defer rt.vtable.deinit(&rt)
    res, err := rt.vtable.run(&rt, "echo", {"hello"}, {}, {}, {})
    testing.expect(t, err == .None, "Expected no error")
    testing.expect(t, res.exit_code == 0, "Expected exit code 0")
}