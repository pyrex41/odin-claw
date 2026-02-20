package main

import "core:fmt"
import "core:net"
import "core:strings"

MAX_BODY_SIZE :: 65536
REQUEST_TIMEOUT_SECS :: 30

Gateway :: struct {
    port: int,
    host: string,
    rate_limiter: ^RateLimiter,
    paired_tokens: []string,
}

RateLimiter :: struct {
    requests_per_minute: u32,
    entries: map[string]int,
}

init_rate_limiter :: proc(limit: u32) -> ^RateLimiter {
    rl := new(RateLimiter)
    rl.requests_per_minute = limit
    rl.entries = make(map[string]int)
    return rl
}

deinit_rate_limiter :: proc(rl: ^RateLimiter) {
    delete(rl.entries)
    free(rl)
}

rate_limiter_allow :: proc(rl: ^RateLimiter, key: string) -> bool {
    if rl.requests_per_minute == 0 {
        return true
    }
    
    count := rl.entries[key]
    if u32(count) >= rl.requests_per_minute {
        return false
    }
    rl.entries[key] = count + 1
    return true
}

Request :: struct {
    method: string,
    path: string,
    headers: map[string]string,
    body: string,
}

Response :: struct {
    status: int,
    body: string,
    content_type: string,
}

handle_request :: proc(req: Request, config: ^Config, gateway: ^Gateway, provider: Provider) -> Response {
    switch req.path {
    case "/health":
        r: Response
        r.status = 200
        r.body = `{"status":"ok"}`
        r.content_type = "application/json"
        return r
    case "/ready":
        r: Response
        r.status = 200
        r.body = `{"status":"ready"}`
        r.content_type = "application/json"
        return r
    case "/webhook":
        return handle_webhook(req, config)
    case "/pair":
        return handle_pair(req, gateway)
    case "/telegram":
        // Handled in server loop (respond-first pattern)
        r: Response
        r.status = 200
        r.body = `{"ok":true}`
        r.content_type = "application/json"
        return r
    case "/whatsapp":
        return handle_whatsapp(req, config)
    case:
        r: Response
        r.status = 404
        r.body = `{"error":"not found"}`
        r.content_type = "application/json"
        return r
    }
}

handle_webhook :: proc(req: Request, config: ^Config) -> Response {
    r: Response
    r.status = 200
    r.body = `{"status":"received"}`
    r.content_type = "application/json"
    return r
}

handle_pair :: proc(req: Request, gateway: ^Gateway) -> Response {
    r: Response
    r.status = 200
    r.body = `{"status":"paired"}`
    r.content_type = "application/json"
    return r
}

// Process telegram webhook after 200 already sent to Telegram
process_telegram_webhook :: proc(req: Request, config: ^Config, provider: Provider) {
    body := req.body
    chat_id := extract_json_int(body, "chat", "id")
    text := extract_json_string(body, "text")

    if chat_id == "" || text == "" {
        return
    }

    fmt.printf("[Telegram] chat_id=%s text=%s\n", chat_id, text)

    // Call the AI provider
    messages := []Message{
        {role = "system", content = "You are OdinClaw, a helpful AI assistant. Be concise."},
        {role = "user", content = text},
    }
    fmt.printf("[Telegram] Calling provider: %s\n", provider.vtable.name(provider.ptr))
    reply_msg, _, err := provider.vtable.chat(provider.ptr, messages, {})

    reply_text := reply_msg.content
    fmt.printf("[Telegram] Provider response: err=%v content_len=%d\n", err, len(reply_text))
    if err != .None || reply_text == "" {
        reply_text = "Sorry, I couldn't process that request."
    }

    // Send reply via Telegram sendMessage API
    token := config.channels.telegram_api_key
    if token != "" {
        send_telegram_reply(token, chat_id, reply_text)
    }
}

// Send a message back to Telegram
send_telegram_reply :: proc(token: string, chat_id: string, text: string) {
    url := fmt.tprintf("https://api.telegram.org/bot%s/sendMessage", token)
    escaped := escape_json_string(text)
    defer delete(escaped)
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"chat_id":`)
    strings.write_string(&sb, chat_id)
    strings.write_string(&sb, `,"text":"`)
    strings.write_string(&sb, escaped)
    strings.write_string(&sb, `"}`)
    body := strings.clone(strings.to_string(sb))
    defer delete(body)
    headers := []string{"Content-Type: application/json"}
    fmt.printf("[Telegram] Sending body: %s\n", body)
    resp, err := http_post_request(url, body, headers)
    if err != .None {
        fmt.printf("[Telegram] Failed to send reply: %v\n", err)
    } else {
        defer delete(resp.body)
        fmt.printf("[Telegram] Reply sent (status=%d) resp=%s\n", resp.status_code, resp.body)
    }
}

// Extract a string value from JSON by key (simple parser)
extract_json_string :: proc(json_str: string, key: string) -> string {
    search := fmt.tprintf(`"%s"`, key)
    idx := strings.index(json_str, search)
    if idx < 0 { return "" }

    // Skip past "key" : "
    pos := idx + len(search)
    for pos < len(json_str) && (json_str[pos] == ':' || json_str[pos] == ' ' || json_str[pos] == '\t') {
        pos += 1
    }
    if pos >= len(json_str) || json_str[pos] != '"' { return "" }
    pos += 1 // skip opening quote

    end := pos
    for end < len(json_str) {
        if json_str[end] == '\\' && end + 1 < len(json_str) {
            end += 2
        } else if json_str[end] == '"' {
            break
        } else {
            end += 1
        }
    }
    if end <= pos { return "" }
    return json_str[pos:end]
}

// Extract a nested integer like "chat":{"id":12345} as a string
extract_json_int :: proc(json_str: string, parent_key: string, child_key: string) -> string {
    // Find the parent object
    parent_search := fmt.tprintf(`"%s"`, parent_key)
    parent_idx := strings.index(json_str, parent_search)
    if parent_idx < 0 { return "" }

    // Search within the parent object for the child key
    child_search := fmt.tprintf(`"%s"`, child_key)
    search_region := json_str[parent_idx:]
    child_idx := strings.index(search_region, child_search)
    if child_idx < 0 { return "" }

    // Skip past "id" :
    pos := child_idx + len(child_search)
    for pos < len(search_region) && (search_region[pos] == ':' || search_region[pos] == ' ') {
        pos += 1
    }
    if pos >= len(search_region) { return "" }

    // Read digits (and possible leading minus)
    start := pos
    if pos < len(search_region) && search_region[pos] == '-' {
        pos += 1
    }
    for pos < len(search_region) && search_region[pos] >= '0' && search_region[pos] <= '9' {
        pos += 1
    }
    if pos <= start { return "" }
    return search_region[start:pos]
}

handle_whatsapp :: proc(req: Request, config: ^Config) -> Response {
    r: Response
    if req.method == "GET" {
        r.status = 200
        r.body = ""
        r.content_type = "text/plain"
    } else {
        r.status = 200
        r.body = `{"status":"received"}`
        r.content_type = "application/json"
    }
    return r
}

parse_http_request :: proc(data: string) -> (Request, bool) {
    req: Request
    req.headers = make(map[string]string)

    lines := strings.split(data, "\r\n")
    if len(lines) == 0 {
        return req, false
    }

    parts := strings.split(lines[0], " ")
    if len(parts) < 2 {
        return req, false
    }
    req.method = parts[0]
    req.path = parts[1]

    i := 1
    for i < len(lines) && lines[i] != "" {
        if idx := strings.index(lines[i], ": "); idx >= 0 {
            key := strings.trim_space(lines[i][:idx])
            value := strings.trim_space(lines[i][idx+2:])
            req.headers[key] = value
        }
        i += 1
    }

    if i + 1 < len(lines) {
        body_lines := lines[i+1:]
        req.body = strings.join(body_lines, "\r\n")
    }

    return req, true
}

build_http_response :: proc(resp: Response) -> string {
    status_text := "OK"
    if resp.status == 404 {
        status_text = "Not Found"
    } else if resp.status == 401 {
        status_text = "Unauthorized"
    } else if resp.status == 429 {
        status_text = "Too Many Requests"
    } else if resp.status == 500 {
        status_text = "Internal Server Error"
    }

    result := strings.builder_make()
    defer strings.builder_destroy(&result)

    strings.write_string(&result, fmt.tprintf("HTTP/1.1 %d %s\r\n", resp.status, status_text))
    strings.write_string(&result, fmt.tprintf("Content-Type: %s\r\n", resp.content_type))
    strings.write_string(&result, fmt.tprintf("Content-Length: %d\r\n", len(resp.body)))
    strings.write_string(&result, "Connection: close\r\n")
    strings.write_string(&result, "\r\n")
    strings.write_string(&result, resp.body)

    return strings.clone(strings.to_string(result))
}

start_gateway :: proc(config: ^Config, host: string, port: int, provider: Provider, tools: []Tool, mem: Memory) {
    rate_limiter := init_rate_limiter(u32(config.gateway.rate_limit))
    defer deinit_rate_limiter(rate_limiter)

    gateway := Gateway{
        port = port,
        host = host,
        rate_limiter = rate_limiter,
        paired_tokens = make([]string, 0),
    }

    endpoint := net.Endpoint{
        address = net.IP4_Any,
        port = port,
    }

    sock, listen_err := net.listen_tcp(endpoint)
    if listen_err != nil {
        fmt.printf("Error: failed to listen on %s:%d: %v\n", host, port, listen_err)
        return
    }
    defer net.close(sock)

    fmt.printf("Gateway listening on %s:%d\n", host, port)

    for {
        client, _, accept_err := net.accept_tcp(sock)
        if accept_err != nil {
            continue
        }

        buf: [65536]u8
        bytes_read, recv_err := net.recv_tcp(client, buf[:])
        if recv_err != nil || bytes_read <= 0 {
            net.close(client)
            continue
        }

        raw := string(buf[:bytes_read])
        req, ok := parse_http_request(raw)
        if !ok {
            net.close(client)
            continue
        }

        // For telegram webhooks: respond 200 immediately, then process async
        if req.path == "/telegram" {
            ok_resp := Response{status = 200, body = `{"ok":true}`, content_type = "application/json"}
            resp_str := build_http_response(ok_resp)
            net.send_tcp(client, transmute([]u8)resp_str)
            net.close(client)
            delete(resp_str)
            // Now process the message (Telegram already got its 200)
            process_telegram_webhook(req, config, provider)
            continue
        }

        resp := handle_request(req, config, &gateway, provider)
        resp_str := build_http_response(resp)
        net.send_tcp(client, transmute([]u8)resp_str)
        net.close(client)
        delete(resp_str)
    }
}
