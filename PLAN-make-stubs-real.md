# OdinClaw: Make Stubs Real - Implementation Plan

## Context

OdinClaw is a ~9,300-line Odin AI assistant runtime that compiles and has working core flows (agent loop, providers, gateway, tools). However, 6 subsystems have code structure but stub implementations. This plan makes them functional. Item 1 (SQLite/FTS5) is handled separately by another agent.

## Items to Implement

2. **Memory tools** - wire store/recall/forget to LMDB backend
3. **WebSocket connections** - real TCP connect + handshake
4. **Tunnel subprocess execution** - actually run tunnel commands
5. **MCP server communication** - subprocess + JSON-RPC over stdio
6. **Cron job execution** - run commands instead of logging
7. **Daemon integration** - gateway thread + cron tick loop

## What We're NOT Doing

- SQLite/FTS5 memory backend (separate agent)
- TLS/wss:// WebSocket support (would need external TLS lib)
- Channel receive implementations (polling/long-poll is a bigger architectural decision)
- IRC TCP socket implementation or SMTP email (different scope)
- Streaming provider integration (SSE parser works but wiring it in changes the provider interface)

## Desired End State

After implementation:
- `odin-claw agent -m "remember my name is Bob"` -> stores in LMDB via memory_store tool
- `odin-claw agent -m "what's my name?"` -> retrieves from LMDB via memory_recall tool
- `odin-claw cron add test "*/5 * * * *" "echo hello"` + daemon -> actually runs `echo hello` every 5 min
- `odin-claw daemon` -> starts gateway in a thread + ticks cron in main loop
- WebSocket: `ws_connect` makes a real TCP connection and completes the HTTP upgrade
- Tunnel: `start_tunnel` launches cloudflared/ngrok/tailscale as a background process
- MCP: can launch an MCP server subprocess, discover its tools, and call them

## Shared Foundation: POSIX Subprocess Utilities

Both MCP and Tunnel need subprocess management. We'll add a minimal `subprocess.odin` with POSIX FFI bindings.

**New file**: `src/subprocess.odin`

```odin
// POSIX FFI for subprocess management
foreign libc {
    fork    :: proc "c" () -> i32 ---
    execvp  :: proc "c" (file: cstring, argv: [^]cstring) -> i32 ---
    pipe    :: proc "c" (pipefd: ^[2]i32) -> i32 ---
    dup2    :: proc "c" (oldfd: i32, newfd: i32) -> i32 ---
    close   :: proc "c" (fd: i32) -> i32 ---
    read    :: proc "c" (fd: i32, buf: rawptr, count: uint) -> int ---
    write   :: proc "c" (fd: i32, buf: rawptr, count: uint) -> int ---
    waitpid :: proc "c" (pid: i32, status: ^i32, options: i32) -> i32 ---
    kill    :: proc "c" (pid: i32, sig: i32) -> i32 ---
}

STDIN_FILENO  :: 0
STDOUT_FILENO :: 1
STDERR_FILENO :: 2
SIGTERM :: 15
WNOHANG :: 1

SubProcess :: struct {
    pid:       i32,
    stdin_fd:  i32,  // parent writes here -> child stdin
    stdout_fd: i32,  // parent reads here <- child stdout
    running:   bool,
}
```

Key procedures:
- `spawn_process(command: string, args: []string) -> (^SubProcess, bool)` - fork+exec with pipes
- `subprocess_write(sp, data: string)` - write to child stdin
- `subprocess_read_line(sp) -> (string, bool)` - read one line from child stdout
- `subprocess_kill(sp)` - send SIGTERM
- `subprocess_is_alive(sp) -> bool` - check with waitpid(WNOHANG)
- `deinit_subprocess(sp)` - close fds, free

---

## Phase 1: Cron Job Execution + Memory Tools (Quick Wins)

### 1a. Cron Job Execution

**File**: `src/cron.odin:191-193`

Current:
```odin
execute_cron_job :: proc(job: ^CronJob) {
    fmt.printf("[Cron] Executing job: %s -> %s\n", job.name, job.command)
}
```

Change to:
```odin
execute_cron_job :: proc(job: ^CronJob) {
    fmt.printf("[Cron] Executing job: %s -> %s\n", job.name, job.command)
    c_cmd := strings.clone_to_cstring(job.command)
    defer delete(c_cmd)
    exit_code := system(c_cmd)
    fmt.printf("[Cron] Job '%s' exit code: %d\n", job.name, exit_code)
}
```

The `system()` foreign function is already declared in `src/runtime.odin:9` and is accessible within the package. Need to add `import "core:strings"` if not already present (it is - line 4).

### 1b. Memory Tools → LMDB

**Problem**: Tool execute signature is `proc(ptr: rawptr, args, config, runtime)`. The `ptr` field is `nil` for all tools. Memory tools need access to a `Memory` backend.

**Solution**: Use the existing `ptr` field on Tool to store a `MemoryToolContext`.

**File**: `src/tools.odin`

Add struct:
```odin
MemoryToolContext :: struct {
    mem: Memory,
}
```

Change `get_tools` signature to accept Memory:
```odin
get_tools :: proc(mem: Memory) -> []Tool {
    // Create shared context for memory tools
    mem_ctx := new(MemoryToolContext)
    mem_ctx.mem = mem

    tools := make([]Tool, 12)
    tools[0] = Tool{ptr = nil, vtable = &shell_tool_vtable}
    // ... tools 1-6 unchanged (ptr = nil) ...
    tools[7] = Tool{ptr = mem_ctx, vtable = &memory_store_tool_vtable}
    tools[8] = Tool{ptr = mem_ctx, vtable = &memory_recall_tool_vtable}
    tools[9] = Tool{ptr = mem_ctx, vtable = &memory_forget_tool_vtable}
    tools[10] = Tool{ptr = nil, vtable = &web_fetch_tool_vtable}
    tools[11] = Tool{ptr = nil, vtable = &web_search_tool_vtable}
    return tools
}
```

Rewrite memory tool execute procs to use LMDB:

```odin
memory_store_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    ctx := (^MemoryToolContext)(ptr)
    if ctx == nil { return Error{"Memory backend not initialized"} }
    // ... get key/value from args (existing validation code) ...
    err := ctx.mem.vtable.store(ctx.mem.ptr, string(key), transmute([]u8)string(value))
    if err != .None { return Error{"Failed to store in memory"} }
    return fmt.tprintf("Stored '%s'", string(key))
}

memory_recall_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    ctx := (^MemoryToolContext)(ptr)
    if ctx == nil { return Error{"Memory backend not initialized"} }
    // ... get query from args ...
    // Try exact key lookup first
    data, err := ctx.mem.vtable.retrieve(ctx.mem.ptr, string(query))
    if err == .None {
        defer delete(data)
        return string(data)
    }
    // Fall back to search
    results := ctx.mem.vtable.search(ctx.mem.ptr, string(query))
    if len(results) == 0 { return "No memories found for that query." }
    // Format results
    // ...
}

memory_forget_tool_execute :: proc(ptr: rawptr, args: map[string]json.Value, config: ^Config, runtime: ^Runtime) -> Result {
    ctx := (^MemoryToolContext)(ptr)
    if ctx == nil { return Error{"Memory backend not initialized"} }
    // ... get key from args ...
    err := ctx.mem.vtable.delete_key(ctx.mem.ptr, string(key))
    if err == .Key_Not_Found { return Error{"Key not found in memory"} }
    if err != .None { return Error{"Failed to delete from memory"} }
    return fmt.tprintf("Deleted '%s' from memory", string(key))
}
```

**Update all callers of `get_tools()`**:

`src/main.odin` - 3 call sites:

1. `run_agent` (line 99): Add Memory init before get_tools
```odin
mem_path := config.memory.db_path
if mem_path == "" { mem_path = "/tmp/odin-claw/memory" }
mem, mem_ok := init_lmdb_memory(mem_path)
if !mem_ok { mem = init_in_memory() }
defer deinit_lmdb_memory(mem) // or deinit_in_memory based on which
tools := get_tools(mem)
```

2. `run_gateway` (line 165): Already creates `mem`, just move it before get_tools
```odin
mem := init_in_memory()
defer deinit_in_memory(mem)
tools := get_tools(mem)
```

3. `run_cli_channel` (line 661): Same pattern as run_gateway

### Phase 1 Success Criteria

#### Automated:
- [ ] Project compiles: `odin build src/ -out:odin-claw`
- [ ] Existing tests pass: `odin test src/`
- [ ] `odin-claw cron add test "0 * * * *" "echo cron-works"` adds without error

#### Manual:
- [ ] `odin-claw agent -m "store key=test value=hello"` → actually stores in LMDB
- [ ] `odin-claw agent -m "recall test"` → returns "hello"

---

## Phase 2: Daemon Integration (Threading)

**File**: `src/daemon.odin`

### Changes Required

Add gateway thread infrastructure:

```odin
import "core:thread"

GatewayThreadCtx :: struct {
    config:   ^Config,
    host:     string,
    port:     int,
    provider: Provider,
    tools:    []Tool,
    mem:      Memory,
}

gateway_thread_proc :: proc(t: ^thread.Thread) {
    ctx := (^GatewayThreadCtx)(t.data)
    start_gateway(ctx.config, ctx.host, ctx.port, ctx.provider, ctx.tools, ctx.mem)
}
```

Rewrite `daemon_main_loop` (lines 141-171):

```odin
daemon_main_loop :: proc(d: ^Daemon) {
    if !d.running { return }

    config := load_or_default_config()
    defer free_config(&config)

    // Init shared resources
    mem_path := config.memory.db_path
    if mem_path == "" { mem_path = "/tmp/odin-claw/memory" }
    mem, mem_ok := init_lmdb_memory(mem_path)
    if !mem_ok { mem = init_in_memory() }

    tools := get_tools(mem)
    defer delete(tools)

    provider := create_provider_from_config(&config)
    defer provider.vtable.deinit(provider.ptr)

    // Start gateway in separate thread
    gw_ctx := new(GatewayThreadCtx)
    gw_ctx.config = &config
    gw_ctx.host = config.gateway.host
    gw_ctx.port = config.gateway.port
    gw_ctx.provider = provider
    gw_ctx.tools = tools
    gw_ctx.mem = mem

    gw_thread := thread.create(gateway_thread_proc)
    gw_thread.data = gw_ctx
    thread.start(gw_thread)
    d.gateway_started = true
    fmt.printf("[daemon] Gateway started in thread on %s:%d\n", config.gateway.host, config.gateway.port)

    // Init cron scheduler
    cs := init_cron_scheduler()
    defer deinit_cron_scheduler(cs)
    start_scheduler(cs)
    d.cron_started = true
    fmt.printf("[daemon] Cron scheduler started\n")

    // Main loop: tick cron + heartbeat
    tick: u64 = 0
    for d.running {
        tick += 1
        tick_scheduler(cs)

        if tick % 60 == 0 {
            fmt.printf("[daemon] Heartbeat tick=%d\n", tick)
        }

        time.sleep(1 * time.Second) // 1s resolution for cron
    }

    // Cleanup
    stop_scheduler(cs)
    thread.destroy(gw_thread)
    free(gw_ctx)
}
```

### Phase 2 Success Criteria

#### Automated:
- [ ] Compiles: `odin build src/ -out:odin-claw`
- [ ] Tests pass: `odin test src/`

#### Manual:
- [ ] `odin-claw daemon` starts, shows gateway + cron messages
- [ ] While daemon runs, `curl localhost:8080/health` returns `{"status":"ok"}`
- [ ] Cron jobs tick as expected (verify with log output)

---

## Phase 3: POSIX Subprocess Utilities + Tunnel Execution

### 3a. Subprocess Utilities

**New file**: `src/subprocess.odin`

POSIX FFI bindings for fork/exec/pipe + wrapper struct and procedures as described in the foundation section above.

Key implementation detail: `spawn_process` does:
1. Create two pipes (parent→child stdin, child→parent stdout)
2. Fork
3. Child: dup2 pipes to stdin/stdout, close unused ends, execvp
4. Parent: close unused pipe ends, return SubProcess with read/write fds

### 3b. Tunnel Execution

**File**: `src/tunnel.odin`

Change `start_tunnel` (lines 108-141) to actually launch the subprocess:

```odin
start_tunnel :: proc(t: ^Tunnel) -> bool {
    if t.running { return false }

    cmd := tunnel_build_command(t)
    if cmd == "" { return false }
    if t.process_cmd != "" { delete(t.process_cmd) }
    t.process_cmd = cmd

    provider_name := tunnel_provider_name(t.config.provider_type)
    fmt.printf("[Tunnel] Starting %s tunnel on port %d\n", provider_name, t.config.local_port)
    fmt.printf("[Tunnel] Command: %s\n", t.process_cmd)

    // Launch as subprocess
    sp, ok := spawn_process(t.process_cmd, {})
    if !ok {
        fmt.printf("[Tunnel] Failed to start subprocess\n")
        return false
    }

    t.running = true
    // Store subprocess handle (add field to Tunnel struct)
    t.subprocess = sp

    // Try to read public URL from stdout (first few lines)
    for i := 0; i < 10; i += 1 {
        line, line_ok := subprocess_read_line(sp)
        if !line_ok { break }
        // Look for URL patterns in output
        if strings.contains(line, "https://") || strings.contains(line, "http://") {
            // Extract URL
            if t.public_url != "" { delete(t.public_url) }
            t.public_url = extract_url_from_line(line)
            fmt.printf("[Tunnel] Public URL: %s\n", t.public_url)
            break
        }
    }

    if t.public_url == "" {
        t.public_url = format_tunnel_url(t) // fallback to placeholder
    }
    return true
}
```

Add `subprocess: ^SubProcess` field to Tunnel struct.

Change `stop_tunnel` to kill the subprocess:
```odin
stop_tunnel :: proc(t: ^Tunnel) {
    if !t.running { return }
    if t.subprocess != nil {
        subprocess_kill(t.subprocess)
        deinit_subprocess(t.subprocess)
        t.subprocess = nil
    }
    t.running = false
}
```

### Phase 3 Success Criteria

#### Automated:
- [ ] Compiles: `odin build src/ -out:odin-claw`
- [ ] Tests pass: `odin test src/`

#### Manual:
- [ ] If cloudflared is installed: tunnel start creates a real tunnel, URL is captured
- [ ] Tunnel stop kills the subprocess

---

## Phase 4: MCP Server Communication

**File**: `src/mcp.odin`

### Changes Required

Add subprocess field to MCP_Server:
```odin
MCP_Server :: struct {
    name:       string,
    command:    string,
    args:       []string,
    tools:      [dynamic]MCP_Tool,
    connected:  bool,
    request_id: int,
    process:    ^SubProcess, // NEW
}
```

Add connection procedure:
```odin
connect_mcp_server :: proc(server: ^MCP_Server) -> MCP_Error {
    sp, ok := spawn_process(server.command, server.args)
    if !ok { return .Connection_Failed }
    server.process = sp

    // Send initialize handshake
    server.request_id += 1
    init_req := build_initialize_request(server.request_id)
    subprocess_write(sp, init_req)
    subprocess_write(sp, "\n")

    // Read initialize response
    response, resp_ok := subprocess_read_line(sp)
    if !resp_ok {
        subprocess_kill(sp)
        return .Connection_Failed
    }
    // Validate response contains "result" (not "error")
    if strings.contains(response, `"error"`) {
        subprocess_kill(sp)
        return .Connection_Failed
    }

    // Send initialized notification (no response expected)
    subprocess_write(sp, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
    subprocess_write(sp, "\n")

    // Discover tools
    server.request_id += 1
    tools_req := build_tools_list_request(server.request_id)
    subprocess_write(sp, tools_req)
    subprocess_write(sp, "\n")

    tools_response, tools_ok := subprocess_read_line(sp)
    if !tools_ok { return .Connection_Failed }

    server.tools = parse_mcp_tools(tools_response)
    server.connected = true

    fmt.printf("[MCP] Connected to '%s', discovered %d tools\n",
        server.name, len(server.tools))
    return .None
}
```

Add tool execution:
```odin
call_mcp_tool :: proc(server: ^MCP_Server, tool_name: string, arguments: string) -> (string, MCP_Error) {
    if !server.connected || server.process == nil {
        return "", .Connection_Failed
    }

    server.request_id += 1
    req := build_tool_call_request(tool_name, arguments, server.request_id)
    subprocess_write(server.process, req)
    subprocess_write(server.process, "\n")

    response, ok := subprocess_read_line(server.process)
    if !ok { return "", .Timeout }

    return parse_mcp_tool_result(response)
}
```

Add disconnect:
```odin
disconnect_mcp_server :: proc(server: ^MCP_Server) {
    if server.process != nil {
        subprocess_kill(server.process)
        deinit_subprocess(server.process)
        server.process = nil
    }
    server.connected = false
}
```

### Phase 4 Success Criteria

#### Automated:
- [ ] Compiles: `odin build src/ -out:odin-claw`

#### Manual:
- [ ] With an MCP server installed (e.g., `npx @modelcontextprotocol/server-filesystem`), can connect, list tools, and call a tool

---

## Phase 5: WebSocket Connections

**File**: `src/websocket.odin`

### Changes Required

Add socket field to connection struct:
```odin
import "core:net"

WebSocket_Connection :: struct {
    url:         string,
    connected:   bool,
    socket:      net.TCP_Socket, // NEW
    on_message:  proc(data: string),
    on_close:    proc(),
    send_buffer: [dynamic]u8,
    recv_buffer: [dynamic]u8,
}
```

Replace stub `ws_connect` (lines 297-314) with real implementation:

```odin
ws_connect :: proc(ws: ^WebSocket_Connection) -> bool {
    host := _extract_host(ws.url)
    port := _extract_port(ws.url)

    // Resolve and connect
    addr4 := net.IP4_Address{127, 0, 0, 1} // fallback
    // For real DNS: would need getaddrinfo FFI
    // For now, parse IP or use known hosts

    endpoint := net.Endpoint{address = addr4, port = port}
    sock, err := net.dial_tcp(endpoint)
    if err != nil {
        fmt.printf("[WebSocket] TCP connect failed: %v\n", err)
        return false
    }

    // Send upgrade handshake
    handshake := ws_build_handshake(ws.url, host)
    net.send_tcp(sock, transmute([]u8)handshake)

    // Read response
    buf: [4096]u8
    n, recv_err := net.recv_tcp(sock, buf[:])
    if recv_err != nil || n <= 0 {
        net.close(sock)
        return false
    }

    response := string(buf[:n])
    if !strings.contains(response, "101") {
        fmt.printf("[WebSocket] Handshake failed: %s\n", response[:min(100, len(response))])
        net.close(sock)
        return false
    }

    ws.socket = sock
    ws.connected = true
    fmt.printf("[WebSocket] Connected to %s\n", ws.url)
    return true
}
```

Update `ws_send_text` to actually send over socket:
```odin
ws_send_text :: proc(ws: ^WebSocket_Connection, text: string) {
    if !ws.connected { return }
    payload := transmute([]byte)text
    frame_data := ws_encode_frame(WS_OPCODE_TEXT, payload, true) // client must mask
    defer delete(frame_data)
    net.send_tcp(ws.socket, frame_data)
}
```

Add `ws_recv` to read frames from socket:
```odin
ws_recv :: proc(ws: ^WebSocket_Connection) -> (string, bool) {
    if !ws.connected { return "", false }
    buf: [65536]u8
    n, err := net.recv_tcp(ws.socket, buf[:])
    if err != nil || n <= 0 { return "", false }

    frame, _, ok := ws_decode_frame(buf[:n])
    if !ok { return "", false }
    defer delete(frame.payload)

    if frame.opcode == WS_OPCODE_TEXT {
        return strings.clone(string(frame.payload)), true
    }
    if frame.opcode == WS_OPCODE_PING {
        // Send pong
        pong := ws_encode_frame(WS_OPCODE_PONG, frame.payload, true)
        defer delete(pong)
        net.send_tcp(ws.socket, pong)
    }
    if frame.opcode == WS_OPCODE_CLOSE {
        ws.connected = false
        net.close(ws.socket)
    }
    return "", false
}
```

Update `ws_disconnect`:
```odin
ws_disconnect :: proc(ws: ^WebSocket_Connection) {
    if !ws.connected { return }
    // Send close frame
    empty: []byte
    close_frame := ws_encode_frame(WS_OPCODE_CLOSE, empty, true)
    defer delete(close_frame)
    net.send_tcp(ws.socket, close_frame)
    ws.connected = false
    net.close(ws.socket)
}
```

Add helper to extract port:
```odin
_extract_port :: proc(url: string) -> int {
    host_str := _extract_host(url)
    if colon := strings.last_index(host_str, ":"); colon >= 0 {
        return fast_atoi(host_str[colon+1:])
    }
    if strings.has_prefix(url, "wss://") { return 443 }
    return 80
}
```

**Limitation**: DNS resolution is not in Odin's core:net. For the initial implementation, the user provides IP addresses or localhost. We can add `getaddrinfo` FFI later.

**Limitation**: wss:// (TLS) is not supported in this phase. Would require an external TLS library binding.

### Phase 5 Success Criteria

#### Automated:
- [ ] Compiles: `odin build src/ -out:odin-claw`

#### Manual:
- [ ] Can connect to a local ws:// WebSocket server (e.g., `ws://localhost:8080`)
- [ ] Can send and receive text frames
- [ ] Ping/pong handling works
- [ ] Clean disconnect

---

## Implementation Order

1. **Phase 1** (Cron + Memory tools) - ~30 min, no new files
2. **Phase 3a** (Subprocess utilities) - ~45 min, new file needed for phases 3b, 4
3. **Phase 2** (Daemon threading) - ~30 min
4. **Phase 1 verification pause**
5. **Phase 3b** (Tunnel) - ~30 min
6. **Phase 4** (MCP) - ~45 min
7. **Phase 5** (WebSocket) - ~30 min

Total: ~6 phases, subprocess utilities are the key dependency for tunnel and MCP.

## Testing Strategy

### Build verification after each phase:
```bash
odin build src/ -out:odin-claw
odin test src/
```

### Integration tests (manual):
1. Memory: `./odin-claw agent -m "store my name as Bob"` then `./odin-claw agent -m "what is my name?"`
2. Cron: Add a job that writes to /tmp, verify file appears
3. Daemon: Start daemon, verify gateway responds and cron ticks
4. Tunnel: `start_tunnel` with cloudflared or ngrok installed
5. MCP: Connect to a test MCP server, list tools, call one
6. WebSocket: Connect to a local echo WebSocket server

## Files Modified

- `src/cron.odin` - execute_cron_job (Phase 1)
- `src/tools.odin` - MemoryToolContext, get_tools, memory tool impls (Phase 1)
- `src/main.odin` - update get_tools callers (Phase 1)
- `src/daemon.odin` - threading, gateway+cron integration (Phase 2)
- `src/subprocess.odin` - NEW, POSIX subprocess management (Phase 3a)
- `src/tunnel.odin` - start_tunnel, stop_tunnel, Tunnel struct (Phase 3b)
- `src/mcp.odin` - connect, call_tool, disconnect, MCP_Server struct (Phase 4)
- `src/websocket.odin` - ws_connect, ws_send, ws_recv, WebSocket_Connection struct (Phase 5)
