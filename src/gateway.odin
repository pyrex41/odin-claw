package main

import "core:fmt"
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

handle_request :: proc(req: Request, config: ^Config, gateway: ^Gateway) -> Response {
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
        return handle_telegram(req, config)
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

handle_telegram :: proc(req: Request, config: ^Config) -> Response {
    r: Response
    r.status = 200
    r.body = `{"ok":true}`
    r.content_type = "application/json"
    return r
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

    return strings.to_string(result)
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

    fmt.printf("Gateway configured on %s:%d\n", host, port)
    fmt.println("Note: Full TCP server requires additional networking setup")
    fmt.println("Endpoints available:")
    fmt.println("  GET  /health    - Health check")
    fmt.println("  GET  /ready     - Readiness probe")
    fmt.println("  POST /webhook   - Generic webhook")
    fmt.println("  POST /pair      - Pairing endpoint")
    fmt.println("  POST /telegram  - Telegram webhook")
    fmt.println("  GET/POST /whatsapp - WhatsApp webhook")
}
