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
    execute:     proc(tool: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result,
    name:        proc(tool: rawptr) -> string,
    description: proc(tool: rawptr) -> string,
    schema:      proc(tool: rawptr) -> string, // Returns JSON schema for function parameters
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

// ============================================================================
// web_fetch tool - Fetch URL and extract readable text (with SSRF protection)
// ============================================================================

WEB_FETCH_MAX_CHARS :: 8000

web_fetch_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    url_val, ok := args["url"]
    if !ok {
        return Error{"Missing 'url' argument"}
    }
    url, url_ok := url_val.(json.String)
    if !url_ok {
        return Error{"'url' must be a string"}
    }

    url_str := string(url)

    // SSRF protection: block private IP ranges
    if is_private_url(url_str) {
        return Error{"URL points to a private/internal address"}
    }

    resp, err := http_get(url_str, {})
    if err != .None {
        return Error{fmt.tprintf("Failed to fetch URL: %v", err)}
    }
    defer delete(resp.body)

    if resp.status_code < 200 || resp.status_code >= 300 {
        return Error{fmt.tprintf("HTTP %d fetching URL", resp.status_code)}
    }

    // Strip HTML to readable text
    text := strip_html(resp.body)
    defer delete(text)

    // Truncate to max chars
    result_text := text
    truncated := false
    if len(text) > WEB_FETCH_MAX_CHARS {
        result_text = text[:WEB_FETCH_MAX_CHARS]
        truncated = true
    }

    if truncated {
        return fmt.tprintf("Content from %s (truncated to %d chars):\n\n%s\n\n[...truncated]", url_str, WEB_FETCH_MAX_CHARS, result_text)
    }
    return fmt.tprintf("Content from %s:\n\n%s", url_str, result_text)
}

web_fetch_tool_name :: proc(ptr: rawptr) -> string {
    return "web_fetch"
}

web_fetch_tool_description :: proc(ptr: rawptr) -> string {
    return "Fetch a URL and return its content as readable text (HTML stripped)"
}

// strip_html removes HTML tags, script/style blocks, and collapses whitespace
strip_html :: proc(html: string) -> string {
    sb := strings.builder_make()
    i := 0
    in_tag := false
    in_script := false
    in_style := false
    last_was_space := false

    for i < len(html) {
        // Check for script/style start
        if !in_tag && i + 7 < len(html) && (html[i] == '<') {
            lower_tag := strings.to_lower(html[i:min(i+10, len(html))])
            defer delete(lower_tag)
            if strings.has_prefix(lower_tag, "<script") {
                in_script = true
                in_tag = true
                i += 1
                continue
            }
            if strings.has_prefix(lower_tag, "<style") {
                in_style = true
                in_tag = true
                i += 1
                continue
            }
        }

        // Check for script/style end
        if in_script && i + 9 <= len(html) {
            lower_end := strings.to_lower(html[i:min(i+9, len(html))])
            defer delete(lower_end)
            if strings.has_prefix(lower_end, "</script") {
                in_script = false
                // Skip to end of tag
                for i < len(html) && html[i] != '>' {
                    i += 1
                }
                if i < len(html) { i += 1 }
                continue
            }
        }
        if in_style && i + 8 <= len(html) {
            lower_end := strings.to_lower(html[i:min(i+8, len(html))])
            defer delete(lower_end)
            if strings.has_prefix(lower_end, "</style") {
                in_style = false
                for i < len(html) && html[i] != '>' {
                    i += 1
                }
                if i < len(html) { i += 1 }
                continue
            }
        }

        // Skip content inside script/style
        if in_script || in_style {
            i += 1
            continue
        }

        if html[i] == '<' {
            in_tag = true
            // Add newline for block elements
            if i + 1 < len(html) {
                next := html[i+1]
                if next == 'p' || next == 'P' || next == 'd' || next == 'D' ||
                   next == 'h' || next == 'H' || next == 'l' || next == 'L' ||
                   next == 'b' || next == 'B' || next == 't' || next == 'T' {
                    strings.write_byte(&sb, '\n')
                    last_was_space = true
                }
            }
            i += 1
            continue
        }

        if html[i] == '>' {
            in_tag = false
            i += 1
            continue
        }

        if in_tag {
            i += 1
            continue
        }

        // Decode common HTML entities
        if html[i] == '&' {
            if i + 4 < len(html) && html[i:i+4] == "&lt;" {
                strings.write_byte(&sb, '<')
                i += 4
                last_was_space = false
                continue
            }
            if i + 4 < len(html) && html[i:i+4] == "&gt;" {
                strings.write_byte(&sb, '>')
                i += 4
                last_was_space = false
                continue
            }
            if i + 5 < len(html) && html[i:i+5] == "&amp;" {
                strings.write_byte(&sb, '&')
                i += 5
                last_was_space = false
                continue
            }
            if i + 6 < len(html) && html[i:i+6] == "&nbsp;" {
                strings.write_byte(&sb, ' ')
                i += 6
                last_was_space = true
                continue
            }
            if i + 6 < len(html) && html[i:i+6] == "&quot;" {
                strings.write_byte(&sb, '"')
                i += 6
                last_was_space = false
                continue
            }
            if i + 6 < len(html) && html[i:i+6] == "&apos;" {
                strings.write_byte(&sb, '\'')
                i += 6
                last_was_space = false
                continue
            }
            // Skip unknown entities
            if end := strings.index(html[i:], ";"); end > 0 && end < 10 {
                i += end + 1
                continue
            }
        }

        // Collapse whitespace
        c := html[i]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            if !last_was_space {
                strings.write_byte(&sb, ' ')
                last_was_space = true
            }
        } else {
            strings.write_byte(&sb, c)
            last_was_space = false
        }
        i += 1
    }

    return strings.to_string(sb)
}

// is_private_url checks if a URL points to a private/internal address
is_private_url :: proc(url: string) -> bool {
    // Extract host from URL
    host_start := 0
    if strings.has_prefix(url, "https://") {
        host_start = 8
    } else if strings.has_prefix(url, "http://") {
        host_start = 7
    } else {
        return true // No scheme = suspicious
    }

    rest := url[host_start:]
    host_end := strings.index_any(rest, ":/")
    host := rest
    if host_end >= 0 {
        host = rest[:host_end]
    }

    // Block private ranges
    if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1" {
        return true
    }
    if strings.has_prefix(host, "10.") || strings.has_prefix(host, "192.168.") {
        return true
    }
    if strings.has_prefix(host, "172.") {
        // 172.16.0.0 - 172.31.255.255
        if len(host) > 4 {
            second_octet := host[4:]
            if dot := strings.index(second_octet, "."); dot > 0 {
                num_str := second_octet[:dot]
                num := fast_atoi(num_str)
                if num >= 16 && num <= 31 {
                    return true
                }
            }
        }
    }
    // Block metadata endpoints
    if host == "169.254.169.254" || strings.has_suffix(host, ".internal") {
        return true
    }

    return false
}

// ============================================================================
// web_search tool - Search the web using Brave Search API
// ============================================================================

web_search_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    query_val, ok := args["query"]
    if !ok {
        return Error{"Missing 'query' argument"}
    }
    query, query_ok := query_val.(json.String)
    if !query_ok {
        return Error{"'query' must be a string"}
    }

    // Get search API key from config or environment
    api_key := config.search_api_key
    if api_key == "" {
        return Error{"No search API key configured. Set BRAVE_SEARCH_API_KEY environment variable."}
    }

    // URL-encode the query
    query_str := string(query)
    encoded_query := url_encode(query_str)
    defer delete(encoded_query)

    url := fmt.tprintf("https://api.search.brave.com/res/v1/web/search?q=%s&count=5", encoded_query)
    headers := []string{
        fmt.tprintf("X-Subscription-Token: %s", api_key),
        "Accept: application/json",
    }
    resp, err := http_get(url, headers)
    if err != .None {
        return Error{fmt.tprintf("Search request failed: %v", err)}
    }
    defer delete(resp.body)

    if resp.status_code < 200 || resp.status_code >= 300 {
        return Error{fmt.tprintf("Search API returned HTTP %d", resp.status_code)}
    }

    // Parse Brave Search results
    return parse_brave_search_results(resp.body)
}

web_search_tool_name :: proc(ptr: rawptr) -> string {
    return "web_search"
}

web_search_tool_description :: proc(ptr: rawptr) -> string {
    return "Search the web for current information. Returns top 5 results with titles, URLs, and snippets."
}

// url_encode encodes a string for use in a URL query parameter
url_encode :: proc(s: string) -> string {
    sb := strings.builder_make()
    for c in s {
        if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
           c == '-' || c == '_' || c == '.' || c == '~' {
            strings.write_rune(&sb, c)
        } else if c == ' ' {
            strings.write_byte(&sb, '+')
        } else {
            // Percent-encode
            b := u8(c)
            hex := "0123456789ABCDEF"
            strings.write_byte(&sb, '%')
            strings.write_byte(&sb, hex[b >> 4])
            strings.write_byte(&sb, hex[b & 0xF])
        }
    }
    return strings.to_string(sb)
}

// parse_brave_search_results extracts title, url, description from Brave Search JSON
parse_brave_search_results :: proc(body: string) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, "Search results:\n\n")

    // Find "results" array
    results_idx := strings.index(body, `"results"`)
    if results_idx < 0 {
        return "No search results found."
    }

    // Find the array start
    arr_start := strings.index(body[results_idx:], "[")
    if arr_start < 0 {
        return "No search results found."
    }
    pos := results_idx + arr_start + 1

    count := 0
    for count < 5 && pos < len(body) {
        // Find next result object
        obj_start := strings.index(body[pos:], "{")
        if obj_start < 0 { break }
        pos += obj_start

        title := extract_json_string(body[pos:], "title")
        url := extract_json_string(body[pos:], "url")
        description := extract_json_string(body[pos:], "description")

        if title != "" && url != "" {
            count += 1
            strings.write_string(&sb, fmt.tprintf("%d. %s\n   %s\n", count, title, url))
            if description != "" {
                strings.write_string(&sb, fmt.tprintf("   %s\n", description))
            }
            strings.write_string(&sb, "\n")
        }

        // Skip past this object
        end := find_matching_brace(body, pos)
        pos = end + 1
    }

    if count == 0 {
        return "No search results found."
    }

    return strings.to_string(sb)
}

// ============================================================================
// Schema procedures for each tool
// ============================================================================

shell_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"}},"required":["command"]}`
}

file_read_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"path":{"type":"string","description":"The file path to read"}},"required":["path"]}`
}

file_write_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"path":{"type":"string","description":"The file path to write to"},"content":{"type":"string","description":"The content to write"}},"required":["path","content"]}`
}

file_edit_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"path":{"type":"string","description":"The file path to edit"},"old":{"type":"string","description":"Text to find and replace"},"new":{"type":"string","description":"Replacement text"}},"required":["path","old","new"]}`
}

file_append_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"path":{"type":"string","description":"The file path to append to"},"content":{"type":"string","description":"Content to append"}},"required":["path","content"]}`
}

git_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"command":{"type":"string","enum":["status","commit","push","pull","log","add","diff","branch","checkout"],"description":"Git command to execute"},"message":{"type":"string","description":"Commit message (for commit command)"},"args":{"type":"string","description":"Additional arguments"}},"required":["command"]}`
}

http_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"url":{"type":"string","description":"The URL to request"},"method":{"type":"string","enum":["GET","POST","PUT","DELETE"],"description":"HTTP method"},"body":{"type":"string","description":"Request body"},"headers":{"type":"string","description":"Request headers"}},"required":["url"]}`
}

memory_store_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"key":{"type":"string","description":"The key to store under"},"value":{"type":"string","description":"The value to store"}},"required":["key","value"]}`
}

memory_recall_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"query":{"type":"string","description":"Search query for memory"}},"required":["query"]}`
}

memory_forget_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"key":{"type":"string","description":"The key to delete"}},"required":["key"]}`
}

web_fetch_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"url":{"type":"string","description":"The URL to fetch"}},"required":["url"]}`
}

web_search_tool_schema :: proc(ptr: rawptr) -> string {
    return `{"type":"object","properties":{"query":{"type":"string","description":"The search query"}},"required":["query"]}`
}

// ============================================================================
// Vtable definitions for all tools
// ============================================================================

shell_tool_vtable := Tool_VTable{
    execute     = shell_tool_execute,
    name        = shell_tool_name,
    description = shell_tool_description,
    schema      = shell_tool_schema,
}

file_read_tool_vtable := Tool_VTable{
    execute     = file_read_tool_execute,
    name        = file_read_tool_name,
    description = file_read_tool_description,
    schema      = file_read_tool_schema,
}

file_write_tool_vtable := Tool_VTable{
    execute     = file_write_tool_execute,
    name        = file_write_tool_name,
    description = file_write_tool_description,
    schema      = file_write_tool_schema,
}

file_edit_tool_vtable := Tool_VTable{
    execute     = file_edit_tool_execute,
    name        = file_edit_tool_name,
    description = file_edit_tool_description,
    schema      = file_edit_tool_schema,
}

file_append_tool_vtable := Tool_VTable{
    execute     = file_append_tool_execute,
    name        = file_append_tool_name,
    description = file_append_tool_description,
    schema      = file_append_tool_schema,
}

git_tool_vtable := Tool_VTable{
    execute     = git_tool_execute,
    name        = git_tool_name,
    description = git_tool_description,
    schema      = git_tool_schema,
}

http_tool_vtable := Tool_VTable{
    execute     = http_tool_execute,
    name        = http_tool_name,
    description = http_tool_description,
    schema      = http_tool_schema,
}

memory_store_tool_vtable := Tool_VTable{
    execute     = memory_store_tool_execute,
    name        = memory_store_tool_name,
    description = memory_store_tool_description,
    schema      = memory_store_tool_schema,
}

memory_recall_tool_vtable := Tool_VTable{
    execute     = memory_recall_tool_execute,
    name        = memory_recall_tool_name,
    description = memory_recall_tool_description,
    schema      = memory_recall_tool_schema,
}

memory_forget_tool_vtable := Tool_VTable{
    execute     = memory_forget_tool_execute,
    name        = memory_forget_tool_name,
    description = memory_forget_tool_description,
    schema      = memory_forget_tool_schema,
}

web_fetch_tool_vtable := Tool_VTable{
    execute     = web_fetch_tool_execute,
    name        = web_fetch_tool_name,
    description = web_fetch_tool_description,
    schema      = web_fetch_tool_schema,
}

web_search_tool_vtable := Tool_VTable{
    execute     = web_search_tool_execute,
    name        = web_search_tool_name,
    description = web_search_tool_description,
    schema      = web_search_tool_schema,
}

// ============================================================================
// get_tools - Returns all 12 available tools
// ============================================================================

get_tools :: proc() -> []Tool {
    tools := make([]Tool, 12)
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
    tools[10] = Tool{ptr = nil, vtable = &web_fetch_tool_vtable}
    tools[11] = Tool{ptr = nil, vtable = &web_search_tool_vtable}
    return tools
}
