package main

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
    // ChaCha20-Poly1305 encryption
    // In full implementation, use crypto package
    s: Secret
    s.key = "default"
    s.value = make([]byte, len(plaintext))
    copy(s.value, plaintext)
    return s, .None
}

decrypt_secret :: proc(secret: Secret, key: []byte) -> (string, Secret_Error) {
    return string(secret.value), .None
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
