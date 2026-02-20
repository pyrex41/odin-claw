package main

import "core:os"
import "core:strings"
import "core:fmt"
import "core:encoding/json"
import "core:testing"

// Tests for tool functionality

@test
test_validate_path :: proc(t: ^testing.T) {
    config := default_config()
    config.tools.workspace_path = "/tmp/test"
    config.tools.allowed_paths = []string{"/home/user"}

    testing.expect(t, validate_path("/tmp/test/file.txt", &config), "Should allow workspace path")
    testing.expect(t, validate_path("/home/user/file.txt", &config), "Should allow allowed path")
    testing.expect(t, !validate_path("/etc/passwd", &config), "Should deny other paths")
}

@test
test_shell_tool :: proc(t: ^testing.T) {
    config := default_config()
    tool := Tool{ptr = nil, vtable = &shell_tool_vtable}
    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)
    args := make(map[string]json.Value)
    defer delete(args)
    args["command"] = json.String("echo hello")

    result := tool.vtable.execute(tool.ptr, args, &config, &runtime)
    switch r in result {
    case string:
        testing.expect(t, strings.contains(r, "exit code 0"), "Shell tool should succeed")
    case Error:
        testing.expect(t, false, fmt.tprintf("Shell tool failed: %s", r.message))
    }

    // Test dangerous command
    args["command"] = json.String("rm -rf /")
    result = tool.vtable.execute(tool.ptr, args, &config, &runtime)
    switch r in result {
    case string:
        testing.expect(t, false, "Dangerous command should fail")
    case Error:
        testing.expect(t, strings.contains(r.message, "not allowed"), "Should block dangerous commands")
    }
}

@test
test_file_read_tool :: proc(t: ^testing.T) {
    config := default_config()
    config.tools.allowed_paths = []string{"/tmp"}
    tool := Tool{ptr = nil, vtable = &file_read_tool_vtable}
    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    // Create test file
    test_path := "/tmp/test_file.txt"
    test_content := "Hello World"
    os.write_entire_file(test_path, transmute([]byte)test_content)
    defer os.remove(test_path)

    args := make(map[string]json.Value)
    defer delete(args)
    args["path"] = json.String(test_path)

    result := tool.vtable.execute(tool.ptr, args, &config, &runtime)
    switch r in result {
    case string:
        testing.expect(t, r == test_content, "Should read file content")
    case Error:
        testing.expect(t, false, fmt.tprintf("File read failed: %s", r.message))
    }

    // Test invalid path
    args["path"] = json.String("/etc/passwd")
    result = tool.vtable.execute(tool.ptr, args, &config, &runtime)
    switch r in result {
    case string:
        testing.expect(t, false, "Should deny invalid path")
    case Error:
        testing.expect(t, strings.contains(r.message, "not allowed"), "Should block invalid path")
    }
}

@test
test_file_edit_tool :: proc(t: ^testing.T) {
    config := default_config()
    config.tools.allowed_paths = []string{"/tmp"}
    tool := Tool{ptr = nil, vtable = &file_edit_tool_vtable}
    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    test_path := "/tmp/test_edit.txt"
    test_content := "Hello World"
    os.write_entire_file(test_path, transmute([]byte)test_content)
    defer os.remove(test_path)

    args := make(map[string]json.Value)
    defer delete(args)
    args["path"] = json.String(test_path)
    args["old"] = json.String("World")
    args["new"] = json.String("Odin")

    result := tool.vtable.execute(tool.ptr, args, &config, &runtime)
    switch r in result {
    case string:
        testing.expect(t, strings.contains(r, "Replaced"), "Should replace text")
    case Error:
        testing.expect(t, false, fmt.tprintf("File edit failed: %s", r.message))
    }
}

@test
test_git_tool :: proc(t: ^testing.T) {
    config := default_config()
    tool := Tool{ptr = nil, vtable = &git_tool_vtable}
    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    args := make(map[string]json.Value)
    defer delete(args)
    args["command"] = json.String("status")

    result := tool.vtable.execute(tool.ptr, args, &config, &runtime)
    switch r in result {
    case string:
        testing.expect(t, strings.contains(r, "Exit code: 0"), "Git status should succeed")
    case Error:
        testing.expect(t, false, fmt.tprintf("Git tool failed: %s", r.message))
    }
}

@test
test_memory_store_tool :: proc(t: ^testing.T) {
    config := default_config()
    tool := Tool{ptr = nil, vtable = &memory_store_tool_vtable}
    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    args := make(map[string]json.Value)
    defer delete(args)
    args["key"] = json.String("test_key")
    args["value"] = json.String("test_value")

    result := tool.vtable.execute(tool.ptr, args, &config, &runtime)
    switch r in result {
    case string:
        testing.expect(t, strings.contains(r, "test_key"), "Should store key")
    case Error:
        testing.expect(t, false, fmt.tprintf("Memory store failed: %s", r.message))
    }
}

@test
test_memory_recall_tool :: proc(t: ^testing.T) {
    config := default_config()
    tool := Tool{ptr = nil, vtable = &memory_recall_tool_vtable}
    runtime := create_native_runtime()
    defer runtime.vtable.deinit(&runtime)

    args := make(map[string]json.Value)
    defer delete(args)
    args["query"] = json.String("test query")

    result := tool.vtable.execute(tool.ptr, args, &config, &runtime)
    switch r in result {
    case string:
        testing.expect(t, strings.contains(r, "test query"), "Should recall query")
    case Error:
        testing.expect(t, false, fmt.tprintf("Memory recall failed: %s", r.message))
    }
}