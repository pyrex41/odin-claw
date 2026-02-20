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

// ============================================================================
// file_edit tool - Edit existing file by replacing text
// ============================================================================

file_edit_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    path_val, ok := args["path"]
    if !ok {
        return Error{"Missing 'path' argument"}
    }
    path, path_ok := path_val.(json.String)
    if !path_ok {
        return Error{"'path' must be a string"}
    }

    old_val, ok2 := args["old"]
    if !ok2 {
        return Error{"Missing 'old' argument - text to replace"}
    }
    old_str, old_ok := old_val.(json.String)
    if !old_ok {
        return Error{"'old' must be a string"}
    }

    new_val, ok3 := args["new"]
    if !ok3 {
        return Error{"Missing 'new' argument - replacement text"}
    }
    new_str, new_ok := new_val.(json.String)
    if !new_ok {
        return Error{"'new' must be a string"}
    }

    if !validate_path(string(path), config) {
        return Error{"Path not allowed"}
    }

    data, read_ok := os.read_entire_file(string(path))
    if !read_ok {
        return Error{"Failed to read file"}
    }
    defer delete(data)

    content := string(data)
    old_text := string(old_str)
    new_text := string(new_str)

    idx := strings.index(content, old_text)
    if idx < 0 {
        return Error{fmt.tprintf("Text '%s' not found in file", old_text)}
    }

    before := content[:idx]
    after := content[idx + len(old_text):]
    new_content := strings.concatenate({before, new_text, after})

    write_ok := os.write_entire_file(string(path), transmute([]u8)new_content)
    if !write_ok {
        return Error{"Failed to write file"}
    }

    return fmt.tprintf("Replaced '%s' with '%s'", old_text, new_text)
}

file_edit_tool_name :: proc(ptr: rawptr) -> string {
    return "file_edit"
}

file_edit_tool_description :: proc(ptr: rawptr) -> string {
    return "Edit a file by replacing text"
}

// ============================================================================
// file_append tool - Append to existing file
// ============================================================================

file_append_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
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

    f, open_err := os.open(string(path), os.O_RDWR | os.O_CREATE | os.O_APPEND, 0o644)
    if open_err != os.ERROR_NONE {
        return Error{fmt.tprintf("Failed to open file: %v", open_err)}
    }
    defer os.close(f)

    written, write_err := os.write(f, transmute([]u8)string(content))
    if write_err != os.ERROR_NONE || written != len(content) {
        return Error{"Failed to write to file"}
    }

    return fmt.tprintf("Appended %d bytes to file", written)
}

file_append_tool_name :: proc(ptr: rawptr) -> string {
    return "file_append"
}

file_append_tool_description :: proc(ptr: rawptr) -> string {
    return "Append content to a file"
}

// ============================================================================
// git tool - Git operations
// ============================================================================

git_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    command_val, ok := args["command"]
    if !ok {
        return Error{"Missing 'command' argument (status, commit, push, pull, log)"}
    }
    command, cmd_ok := command_val.(json.String)
    if !cmd_ok {
        return Error{"'command' must be a string"}
    }

    git_cmd := string(command)

    message_val, has_message := args["message"]
    args_val, has_args := args["args"]

    full_cmd: string

    switch git_cmd {
    case "status":
        full_cmd = "git status"
    case "commit":
        if !has_message {
            return Error{"Missing 'message' argument for commit"}
        }
        msg, msg_ok := message_val.(json.String)
        if !msg_ok {
            return Error{"'message' must be a string"}
        }
        full_cmd = fmt.tprintf("git commit -m \"%s\"", string(msg))
    case "push":
        full_cmd = "git push"
    case "pull":
        full_cmd = "git pull"
    case "log":
        full_cmd = "git log --oneline -10"
    case "add":
        if has_args {
            add_args, args_ok := args_val.(json.String)
            if args_ok {
                full_cmd = fmt.tprintf("git add %s", string(add_args))
            } else {
                full_cmd = "git add ."
            }
        } else {
            full_cmd = "git add ."
        }
    case "diff":
        full_cmd = "git diff"
    case "branch":
        full_cmd = "git branch -a"
    case "checkout":
        if has_args {
            branch, args_ok := args_val.(json.String)
            if args_ok {
                full_cmd = fmt.tprintf("git checkout %s", string(branch))
            } else {
                return Error{"'args' must be a string for checkout"}
            }
        } else {
            return Error{"Missing 'args' for checkout (branch name)"}
        }
    case:
        return Error{fmt.tprintf("Unknown git command: %s", git_cmd)}
    }

    limits := Runtime_Limits{}
    path_control := Path_Control{}
    result, err := runtime.vtable.run(runtime, full_cmd, {}, {}, limits, path_control)
    if err != .None {
        return Error{fmt.tprintf("Git command failed: %v", err)}
    }

    return fmt.tprintf("Exit code: %d", result.exit_code)
}

git_tool_name :: proc(ptr: rawptr) -> string {
    return "git"
}

git_tool_description :: proc(ptr: rawptr) -> string {
    return "Execute git commands (status, commit, push, pull, log, add, diff, branch, checkout)"
}

// ============================================================================
// http_request tool - Make HTTP requests
// ============================================================================

http_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    url_val, ok := args["url"]
    if !ok {
        return Error{"Missing 'url' argument"}
    }
    url, url_ok := url_val.(json.String)
    if !url_ok {
        return Error{"'url' must be a string"}
    }

    method_val, has_method := args["method"]
    body_val, has_body := args["body"]
    headers_val, has_headers := args["headers"]

    method := "GET"
    if has_method {
        m, m_ok := method_val.(json.String)
        if m_ok {
            method = string(m)
        }
    }

    body := ""
    if has_body {
        b, b_ok := body_val.(json.String)
        if b_ok {
            body = string(b)
        }
    }

    headers: []string
    if has_headers {
        headers = make([]string, 0)
        // headers should be an array - simplified for now
    }

    resp, err := http_request(method, string(url), body, headers)
    if err != .None {
        return Error{fmt.tprintf("HTTP request failed: %v", err)}
    }

    return fmt.tprintf("Status: %d\n%s", resp.status_code, resp.body)
}

http_tool_name :: proc(ptr: rawptr) -> string {
    return "http_request"
}

http_tool_description :: proc(ptr: rawptr) -> string {
    return "Make HTTP requests (GET, POST, PUT, DELETE)"
}

// ============================================================================
// Memory tools - Store, Recall, Forget
// ============================================================================

// These require access to a global memory instance - we'll use a placeholder
// In production, this would be passed through the runtime context

memory_store_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    key_val, ok := args["key"]
    if !ok {
        return Error{"Missing 'key' argument"}
    }
    key, key_ok := key_val.(json.String)
    if !key_ok {
        return Error{"'key' must be a string"}
    }

    value_val, ok2 := args["value"]
    if !ok2 {
        return Error{"Missing 'value' argument"}
    }
    value, value_ok := value_val.(json.String)
    if !value_ok {
        return Error{"'value' must be a string"}
    }

    // In a full implementation, this would use the agent's memory
    // For now, we return a placeholder indicating the tool is available
    return fmt.tprintf("Memory store: key='%s', value='%s' (configure memory backend for persistence)", string(key), string(value))
}

memory_store_tool_name :: proc(ptr: rawptr) -> string {
    return "memory_store"
}

memory_store_tool_description :: proc(ptr: rawptr) -> string {
    return "Store a value in memory with a key"
}

memory_recall_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    query_val, ok := args["query"]
    if !ok {
        return Error{"Missing 'query' argument"}
    }
    query, query_ok := query_val.(json.String)
    if !query_ok {
        return Error{"'query' must be a string"}
    }

    // In a full implementation, this would search the memory
    return fmt.tprintf("Memory recall for query: '%s' (configure memory backend for search)", string(query))
}

memory_recall_tool_name :: proc(ptr: rawptr) -> string {
    return "memory_recall"
}

memory_recall_tool_description :: proc(ptr: rawptr) -> string {
    return "Search memory for a query string"
}

memory_forget_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    key_val, ok := args["key"]
    if !ok {
        return Error{"Missing 'key' argument"}
    }
    key, key_ok := key_val.(json.String)
    if !key_ok {
        return Error{"'key' must be a string"}
    }

    // In a full implementation, this would delete from memory
    return fmt.tprintf("Memory forget: key='%s' (configure memory backend for deletion)", string(key))
}

memory_forget_tool_name :: proc(ptr: rawptr) -> string {
    return "memory_forget"
}

memory_forget_tool_description :: proc(ptr: rawptr) -> string {
    return "Delete a key from memory"
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

file_edit_tool_vtable := Tool_VTable{
    execute = file_edit_tool_execute,
    name = file_edit_tool_name,
    description = file_edit_tool_description,
}

file_append_tool_vtable := Tool_VTable{
    execute = file_append_tool_execute,
    name = file_append_tool_name,
    description = file_append_tool_description,
}

git_tool_vtable := Tool_VTable{
    execute = git_tool_execute,
    name = git_tool_name,
    description = git_tool_description,
}

http_tool_vtable := Tool_VTable{
    execute = http_tool_execute,
    name = http_tool_name,
    description = http_tool_description,
}

memory_store_tool_vtable := Tool_VTable{
    execute = memory_store_tool_execute,
    name = memory_store_tool_name,
    description = memory_store_tool_description,
}

memory_recall_tool_vtable := Tool_VTable{
    execute = memory_recall_tool_execute,
    name = memory_recall_tool_name,
    description = memory_recall_tool_description,
}

memory_forget_tool_vtable := Tool_VTable{
    execute = memory_forget_tool_execute,
    name = memory_forget_tool_name,
    description = memory_forget_tool_description,
}

// Get available tools
get_tools :: proc() -> []Tool {
    tools := make([]Tool, 10)
    tools[0] = Tool{ptr = nil, vtable = &shell_tool_vtable}
    tools[1] = Tool{ptr = nil, vtable = &file_read_tool_vtable}
    tools[2] = Tool{ptr = nil, vtable = &file_write_tool_vtable}
    tools[3] = Tool{ptr = nil, vtable = &file_edit_tool_vtable}
    tools[4] = Tool{ptr = nil, vtable = &file_append_tool_vtable}
    tools[5] = Tool{ptr = nil, vtable = &git_tool_vtable}
    tools[6] = Tool{ptr = nil, vtable = &http_tool_vtable}
    tools[7] = Tool{ptr = nil, vtable = &memory_store_tool_vtable}
    tools[8] = Tool{ptr = nil, vtable = &memory_recall_tool_vtable}
    tools[9] = Tool{ptr = nil, vtable = &memory_forget_tool_vtable}
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