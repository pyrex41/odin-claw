package main

import "core:fmt"
import "core:os"
import "core:strings"

// MCP (Model Context Protocol) client for connecting to MCP servers
// Implements JSON-RPC 2.0 over stdio for tool discovery and execution

MCP_Error :: enum {
    None,
    Connection_Failed,
    Parse_Error,
    Invalid_Response,
    Tool_Not_Found,
    Execution_Failed,
    Timeout,
}

// MCP_Tool represents a tool discovered from an MCP server
MCP_Tool :: struct {
    name:        string,
    description: string,
    input_schema: string, // JSON schema for parameters
}

// MCP_Server represents a connection to an MCP server
MCP_Server :: struct {
    name:       string,
    command:    string,   // Command to launch the server (e.g., "npx @modelcontextprotocol/server-filesystem")
    args:       []string,
    tools:      [dynamic]MCP_Tool,
    connected:  bool,
    request_id: int,
}

// MCP_Client manages multiple MCP server connections
MCP_Client :: struct {
    servers: [dynamic]MCP_Server,
}

init_mcp_client :: proc() -> ^MCP_Client {
    c := new(MCP_Client)
    c.servers = make([dynamic]MCP_Server)
    return c
}

deinit_mcp_client :: proc(c: ^MCP_Client) {
    for &server in c.servers {
        deinit_mcp_server(&server)
    }
    delete(c.servers)
    free(c)
}

deinit_mcp_server :: proc(server: ^MCP_Server) {
    delete(server.name)
    delete(server.command)
    for &tool in server.tools {
        delete(tool.name)
        delete(tool.description)
        delete(tool.input_schema)
    }
    delete(server.tools)
}

// add_server registers a new MCP server configuration
add_mcp_server :: proc(c: ^MCP_Client, name: string, command: string, args: []string) {
    server := MCP_Server{
        name    = strings.clone(name),
        command = strings.clone(command),
        args    = args,
        tools   = make([dynamic]MCP_Tool),
    }
    append(&c.servers, server)
    fmt.printf("[MCP] Registered server '%s' (command: %s)\n", name, command)
}

// build_jsonrpc_request creates a JSON-RPC 2.0 request string
build_jsonrpc_request :: proc(method: string, params: string, id: int) -> string {
    if params == "" {
        return fmt.tprintf(`{"jsonrpc":"2.0","method":"%s","id":%d}`, method, id)
    }
    return fmt.tprintf(`{"jsonrpc":"2.0","method":"%s","params":%s,"id":%d}`, method, params, id)
}

// build_initialize_request creates the MCP initialize handshake request
build_initialize_request :: proc(id: int) -> string {
    params := `{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"odin-claw","version":"1.0.0"}}`
    return build_jsonrpc_request("initialize", params, id)
}

// build_tools_list_request creates a request to list available tools
build_tools_list_request :: proc(id: int) -> string {
    return build_jsonrpc_request("tools/list", "", id)
}

// build_tool_call_request creates a request to execute a tool
build_tool_call_request :: proc(tool_name: string, arguments: string, id: int) -> string {
    params := fmt.tprintf(`{"name":"%s","arguments":%s}`, tool_name, arguments)
    return build_jsonrpc_request("tools/call", params, id)
}

// parse_tools_from_response extracts tool definitions from a tools/list response
parse_mcp_tools :: proc(response: string) -> [dynamic]MCP_Tool {
    tools := make([dynamic]MCP_Tool)

    // Find "tools" array in response
    tools_idx := strings.index(response, `"tools"`)
    if tools_idx < 0 {
        return tools
    }

    region := response[tools_idx:]

    // Find array start
    arr_start := strings.index(region, "[")
    if arr_start < 0 {
        return tools
    }

    // Parse each tool object
    pos := arr_start + 1
    for pos < len(region) {
        // Find next tool object
        obj_start := strings.index(region[pos:], "{")
        if obj_start < 0 {
            break
        }
        pos += obj_start

        // Find matching closing brace
        end := find_matching_brace(region, pos)
        if end < 0 {
            break
        }

        tool_json := region[pos:end+1]

        tool := MCP_Tool{
            name        = strings.clone(extract_json_string(tool_json, "name")),
            description = strings.clone(extract_json_string(tool_json, "description")),
        }

        // Extract inputSchema as raw JSON
        schema_idx := strings.index(tool_json, `"inputSchema"`)
        if schema_idx >= 0 {
            after_colon := strings.index(tool_json[schema_idx:], ":")
            if after_colon >= 0 {
                schema_start := schema_idx + after_colon + 1
                // Skip whitespace
                for schema_start < len(tool_json) && (tool_json[schema_start] == ' ' || tool_json[schema_start] == '\t') {
                    schema_start += 1
                }
                if schema_start < len(tool_json) && tool_json[schema_start] == '{' {
                    schema_end := find_matching_brace(tool_json, schema_start)
                    if schema_end >= 0 {
                        tool.input_schema = strings.clone(tool_json[schema_start:schema_end+1])
                    }
                }
            }
        }

        append(&tools, tool)
        pos = end + 1
    }

    return tools
}

// parse_tool_result extracts the text content from a tools/call response
parse_mcp_tool_result :: proc(response: string) -> (string, MCP_Error) {
    // Check for error
    if strings.contains(response, `"error"`) {
        error_msg := extract_json_string(response, "message")
        if error_msg != "" {
            return error_msg, .Execution_Failed
        }
        return "MCP tool execution failed", .Execution_Failed
    }

    // Extract text from result.content[0].text
    text := extract_json_string(response, "text")
    if text != "" {
        return text, .None
    }

    // Try extracting from result directly
    result_text := extract_json_string(response, "result")
    if result_text != "" {
        return result_text, .None
    }

    return "", .Invalid_Response
}

// get_all_mcp_tools returns all tools from all connected servers
get_all_mcp_tools :: proc(c: ^MCP_Client) -> []MCP_Tool {
    all := make([dynamic]MCP_Tool)
    for server in c.servers {
        for tool in server.tools {
            append(&all, tool)
        }
    }
    return all[:]
}

// find_mcp_tool_server finds which server provides a given tool
find_mcp_tool_server :: proc(c: ^MCP_Client, tool_name: string) -> (^MCP_Server, bool) {
    for &server in c.servers {
        for tool in server.tools {
            if tool.name == tool_name {
                return &server, true
            }
        }
    }
    return nil, false
}
