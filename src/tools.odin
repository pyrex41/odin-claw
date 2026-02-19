package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Error represents an error in tool execution
Error :: struct {
    message: string,
}

// Result represents the outcome of a tool execution
Result :: union {
    string, // success result, usually JSON string
    Error,
}

// Tool vtable for executable tools
Tool_VTable :: struct {
    execute: proc(tool: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result,
    name: proc(tool: rawptr) -> string,
    description: proc(tool: rawptr) -> string,
}

Tool :: struct {
    ptr: rawptr,
    vtable: ^Tool_VTable,
}

// validate_path checks if the given path is allowed based on config
validate_path :: proc(path: string, config: ^Config) -> bool {
    // Allow absolute paths within workspace
    if strings.has_prefix(path, config.tools.workspace_path) {
        return true
    }
    // Check against allowed paths
    for allowed in config.tools.allowed_paths {
        if strings.has_prefix(path, allowed) {
            return true
        }
    }
    return false
}

// shell_tool executes shell commands
shell_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    command_val, ok := args["command"]
    if !ok {
        return Error{"Missing 'command' argument"}
    }
    command, cmd_ok := command_val.(json.String)
    if !cmd_ok {
        return Error{"'command' must be a string"}
    }

    // Basic security: prevent dangerous commands
    dangerous := []string{"rm", "sudo", "su", "chmod", "chown", "dd", "mkfs", "dd"}
    cmd_str := string(command)
    for cmd in dangerous {
        if strings.has_prefix(cmd_str, cmd) {
            return Error{"Command not allowed"}
        }
    }

    // Use runtime to execute
    path_control := Path_Control{
        allowed_paths = config.tools.allowed_paths,
        chroot = "",
    }
    limits := Runtime_Limits{
        memory_mb = config.runtime.memory_limit,
        cpu_seconds = 0,
        disk_mb = config.runtime.disk_limit,
    }

    result, err := runtime.vtable.run(runtime, cmd_str, {}, {}, limits, path_control)
    if err != .None {
        return Error{fmt.tprintf("Command failed: %v", err)}
    }

    return fmt.tprintf("Command executed with exit code %d", result.exit_code)
}

// file_read_tool reads a file
file_read_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    path_val, ok := args["path"]
    if !ok {
        return Error{"Missing 'path' argument"}
    }
    path, path_ok := path_val.(json.String)
    if !path_ok {
        return Error{"'path' must be a string"}
    }

    if !validate_path(string(path), config) {
        return Error{"Path not allowed"}
    }

    data, read_ok := os.read_entire_file(string(path))
    if !read_ok {
        return Error{"Failed to read file"}
    }
    defer delete(data)

    // Return as JSON string
    return string(data)
}

// file_write_tool writes to a file
file_write_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    path_val, ok := args["path"]
    if !ok {
        return Error{"Missing 'path' argument"}
    }
    path, path_ok := path_val.(json.String)
    if !path_ok {
        return Error{"'path' must be a string"}
    }

    content_val, ok2 := args["content"]
    if !ok2 {
        return Error{"Missing 'content' argument"}
    }
    content, content_ok := content_val.(json.String)
    if !content_ok {
        return Error{"'content' must be a string"}
    }

    if !validate_path(string(path), config) {
        return Error{"Path not allowed"}
    }

    write_ok := os.write_entire_file(string(path), transmute([]u8)string(content))
    if !write_ok {
        return Error{"Failed to write file"}
    }

    return "File written successfully"
}

// Shell tool name
shell_tool_name :: proc(ptr: rawptr) -> string {
    return "shell"
}

// Shell tool description
shell_tool_description :: proc(ptr: rawptr) -> string {
    return "Execute shell commands"
}

// File read tool name
file_read_tool_name :: proc(ptr: rawptr) -> string {
    return "file_read"
}

// File read tool description
file_read_tool_description :: proc(ptr: rawptr) -> string {
    return "Read a file"
}

// File write tool name
file_write_tool_name :: proc(ptr: rawptr) -> string {
    return "file_write"
}

// File write tool description
file_write_tool_description :: proc(ptr: rawptr) -> string {
    return "Write to a file"
}

// generate_schema generates JSON schema for a tool
generate_schema :: proc(tool: Tool) -> string {
    // Simple schema generation
    name := tool.vtable.name(tool.ptr)
    schema := fmt.tprintf(`{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "enum": ["%s"]
    }
  },
  "required": ["name"]
}`, name)
    return schema
}

// Vtables
shell_tool_vtable := Tool_VTable{
    execute = shell_tool_execute,
    name = shell_tool_name,
    description = shell_tool_description,
}

file_read_tool_vtable := Tool_VTable{
    execute = file_read_tool_execute,
    name = file_read_tool_name,
    description = file_read_tool_description,
}

file_write_tool_vtable := Tool_VTable{
    execute = file_write_tool_execute,
    name = file_write_tool_name,
    description = file_write_tool_description,
}

// Get available tools
get_tools :: proc() -> []Tool {
    tools := make([]Tool, 3)
    tools[0] = Tool{ptr = nil, vtable = &shell_tool_vtable}
    tools[1] = Tool{ptr = nil, vtable = &file_read_tool_vtable}
    tools[2] = Tool{ptr = nil, vtable = &file_write_tool_vtable}
    return tools
}

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