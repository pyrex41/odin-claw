package main

import crypto "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:fmt"
import "core:os"
import "core:strings"

Sandbox_Error :: enum {
    None,
    Not_Supported,
    Init_Failed,
    Path_Denied,
    Network_Denied,
    Limit_Exceeded,
}

Sandbox_VTable :: struct {
    init: proc(ptr: rawptr, config: ^Config) -> Sandbox_Error,
    restrict_path: proc(ptr: rawptr, path: string) -> Sandbox_Error,
    restrict_network: proc(ptr: rawptr, allowed_domains: []string) -> Sandbox_Error,
    apply_limits: proc(ptr: rawptr, memory_mb: int, cpu_percent: int) -> Sandbox_Error,
    deinit: proc(ptr: rawptr),
}

Sandbox :: struct {
    ptr: rawptr,
    vtable: ^Sandbox_VTable,
}

NativeSandbox :: struct {
    enabled: bool,
    allowed_paths: []string,
    chroot_path: string,
}

init_native_sandbox :: proc(config: ^Config) -> Sandbox {
    ns := new(NativeSandbox)
    ns.enabled = true
    ns.allowed_paths = config.runtime.allowed_paths
    ns.chroot_path = ""
    return Sandbox{ptr = ns, vtable = &native_sandbox_vtable}
}

native_sandbox_vtable := Sandbox_VTable{
    init = native_sandbox_init,
    restrict_path = native_sandbox_restrict_path,
    restrict_network = native_sandbox_restrict_network,
    apply_limits = native_sandbox_apply_limits,
    deinit = native_sandbox_deinit,
}

native_sandbox_init :: proc(ptr: rawptr, config: ^Config) -> Sandbox_Error {
    ns := (^NativeSandbox)(ptr)
    ns.enabled = true
    ns.allowed_paths = config.runtime.allowed_paths
    return .None
}

native_sandbox_restrict_path :: proc(ptr: rawptr, path: string) -> Sandbox_Error {
    ns := (^NativeSandbox)(ptr)
    // Check if path is in allowed list
    for allowed in ns.allowed_paths {
        if strings.has_prefix(path, allowed) {
            return .None
        }
    }
    return .Path_Denied
}

native_sandbox_restrict_network :: proc(ptr: rawptr, allowed_domains: []string) -> Sandbox_Error {
    // Native sandbox doesn't restrict network by default
    return .None
}

native_sandbox_apply_limits :: proc(ptr: rawptr, memory_mb: int, cpu_percent: int) -> Sandbox_Error {
    // Resource limits would require syscall or cgroup manipulation
    // This is a placeholder
    return .None
}

native_sandbox_deinit :: proc(ptr: rawptr) {
    ns := (^NativeSandbox)(ptr)
    free(ns)
}

Secret_Error :: enum {
    None,
    Encryption_Failed,
    Decryption_Failed,
    Key_Not_Found,
}

Secret :: struct {
    key: string,
    value: []byte,
}

encrypt_secret :: proc(plaintext: string, key: []byte) -> (Secret, Secret_Error) {
    if len(key) != chacha20poly1305.KEY_SIZE {
        return Secret{}, .Encryption_Failed
    }

    plaintext_bytes := transmute([]u8)plaintext

    // Initialize ChaCha20-Poly1305 context
    ctx: chacha20poly1305.Context
    chacha20poly1305.init(&ctx, key)
    defer chacha20poly1305.reset(&ctx)

    // Generate a cryptographically random nonce
    nonce: [chacha20poly1305.IV_SIZE]u8
    crypto.rand_bytes(nonce[:])

    // Output: nonce + ciphertext + tag
    output_len := chacha20poly1305.IV_SIZE + len(plaintext) + chacha20poly1305.TAG_SIZE
    output := make([]byte, output_len)

    // Copy nonce to output
    copy(output[:chacha20poly1305.IV_SIZE], nonce[:])

    // Encrypt: seal(ctx, dst, tag, iv, aad, plaintext)
    ciphertext := output[chacha20poly1305.IV_SIZE:chacha20poly1305.IV_SIZE + len(plaintext)]
    tag := output[chacha20poly1305.IV_SIZE + len(plaintext):]

    chacha20poly1305.seal(&ctx, ciphertext, tag, nonce[:], nil, plaintext_bytes)

    s: Secret
    s.key = "encrypted"
    s.value = output
    return s, .None
}

decrypt_secret :: proc(secret: Secret, key: []byte) -> (string, Secret_Error) {
    if len(key) != chacha20poly1305.KEY_SIZE {
        return "", .Decryption_Failed
    }
    if len(secret.value) < chacha20poly1305.IV_SIZE + chacha20poly1305.TAG_SIZE {
        return "", .Decryption_Failed
    }

    // Extract nonce, ciphertext, and tag
    nonce := secret.value[:chacha20poly1305.IV_SIZE]
    ciphertext_len := len(secret.value) - chacha20poly1305.IV_SIZE - chacha20poly1305.TAG_SIZE
    ciphertext := secret.value[chacha20poly1305.IV_SIZE:chacha20poly1305.IV_SIZE + ciphertext_len]
    tag := secret.value[chacha20poly1305.IV_SIZE + ciphertext_len:]

    // Initialize ChaCha20-Poly1305 context
    ctx: chacha20poly1305.Context
    chacha20poly1305.init(&ctx, key)
    defer chacha20poly1305.reset(&ctx)

    // Decrypt: open(ctx, dst, iv, aad, ciphertext, tag) -> bool
    plaintext := make([]byte, ciphertext_len)
    ok := chacha20poly1305.open(&ctx, plaintext, nonce, nil, ciphertext, tag)
    if !ok {
        delete(plaintext)
        return "", .Decryption_Failed
    }

    return string(plaintext), .None
}

// is_private_ip checks if a hostname resolves to a private IP range (SSRF protection)
is_private_ip :: proc(host: string) -> bool {
    // Block common private/reserved ranges
    private_prefixes := []string{
        "10.", "172.16.", "172.17.", "172.18.", "172.19.",
        "172.20.", "172.21.", "172.22.", "172.23.", "172.24.",
        "172.25.", "172.26.", "172.27.", "172.28.", "172.29.",
        "172.30.", "172.31.", "192.168.", "127.", "0.",
        "169.254.", "::1", "fc00:", "fd00:", "fe80:",
    }
    for prefix in private_prefixes {
        if strings.has_prefix(host, prefix) {
            return true
        }
    }
    // Block localhost aliases
    if host == "localhost" || host == "0.0.0.0" {
        return true
    }
    return false
}

// validate_url_for_ssrf checks if a URL is safe to fetch (not pointing to internal resources)
validate_url_for_ssrf :: proc(url: string) -> bool {
    // Extract host from URL
    host := url
    if idx := strings.index(url, "://"); idx >= 0 {
        host = url[idx + 3:]
    }
    // Remove path
    if idx := strings.index(host, "/"); idx >= 0 {
        host = host[:idx]
    }
    // Remove port
    if idx := strings.index(host, ":"); idx >= 0 {
        host = host[:idx]
    }

    return !is_private_ip(host)
}

AuditEntry :: struct {
    timestamp: i64,
    action: string,
    user: string,
    resource: string,
    result: string,
}

AuditLog :: struct {
    entries: [dynamic]AuditEntry,
    file_path: string,
}

init_audit_log :: proc(file_path: string) -> ^AuditLog {
    al := new(AuditLog)
    al.entries = make([dynamic]AuditEntry)
    al.file_path = file_path
    return al
}

deinit_audit_log :: proc(al: ^AuditLog) {
    delete(al.entries)
    free(al)
}

log_audit :: proc(al: ^AuditLog, action: string, user: string, resource: string, result: string) {
    entry: AuditEntry
    entry.action = action
    entry.user = user
    entry.resource = resource
    entry.result = result
    append(&al.entries, entry)

    line := fmt.tprintf("[AUDIT] %s: %s %s -> %s\n", action, user, resource, result)
    fmt.print(line)

    if al.file_path != "" {
        fd, err := os.open(al.file_path, os.O_WRONLY | os.O_CREATE | os.O_APPEND, 0o644)
        if err == os.ERROR_NONE {
            os.write_string(fd, line)
            os.close(fd)
        }
    }
}
