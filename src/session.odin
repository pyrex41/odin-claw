package main

import "core:fmt"
import "core:strings"
import "core:time"

// Session holds chat history for a channel:user pair
Session :: struct {
    session_id:   string,
    channel:      string,
    user_id:      string,
    history:      [dynamic]Message,
    created_at:   i64,
    last_active:  i64,
}

// SessionStore manages all active sessions backed by LMDB
SessionStore :: struct {
    sessions:    map[string]Session,
    mem:         Memory, // LMDB backend
    max_history: int,
    ttl_seconds: i64,
}

init_session_store :: proc(mem: Memory, max_history: int, ttl_seconds: i64) -> ^SessionStore {
    store := new(SessionStore)
    store.sessions = make(map[string]Session)
    store.mem = mem
    store.max_history = max_history > 0 ? max_history : 50
    store.ttl_seconds = ttl_seconds > 0 ? ttl_seconds : 86400
    return store
}

deinit_session_store :: proc(store: ^SessionStore) {
    for key, session in &store.sessions {
        delete(session.session_id)
        delete(session.channel)
        delete(session.user_id)
        for msg in session.history {
            delete(msg.role)
            delete(msg.content)
        }
        delete(session.history)
    }
    delete(store.sessions)
    free(store)
}

// session_key builds the lookup key from channel + user_id
make_session_key :: proc(channel: string, user_id: string) -> string {
    return fmt.tprintf("%s:%s", channel, user_id)
}

// load_session loads or creates a session, returning it by value
load_session :: proc(store: ^SessionStore, channel: string, user_id: string) -> Session {
    key := make_session_key(channel, user_id)
    now := time.time_to_unix(time.now())

    // Check in-memory cache first
    if existing, ok := &store.sessions[key]; ok {
        // Check TTL
        if store.ttl_seconds > 0 && (now - existing.last_active) > store.ttl_seconds {
            // Session expired, clear history
            for msg in existing.history {
                delete(msg.role)
                delete(msg.content)
            }
            clear(&existing.history)
            existing.created_at = now
        }
        existing.last_active = now
        // Return a copy
        return copy_session(existing^)
    }

    // Try loading from LMDB
    session := Session{
        session_id  = strings.clone(key),
        channel     = strings.clone(channel),
        user_id     = strings.clone(user_id),
        history     = make([dynamic]Message),
        created_at  = now,
        last_active = now,
    }

    data, mem_err := store.mem.vtable.retrieve(store.mem.ptr, key)
    if mem_err == .None && len(data) > 0 {
        deserialize_session_history(&session, string(data))
        delete(data)

        // Check TTL on loaded session
        if store.ttl_seconds > 0 && (now - session.last_active) > store.ttl_seconds {
            for msg in session.history {
                delete(msg.role)
                delete(msg.content)
            }
            clear(&session.history)
            session.created_at = now
        }
    }

    session.last_active = now

    // Cache it
    cloned_key := strings.clone(key)
    store.sessions[cloned_key] = copy_session(session)

    return session
}

// save_session persists session history to LMDB and updates cache
save_session :: proc(store: ^SessionStore, session: ^Session) {
    key := make_session_key(session.channel, session.user_id)

    // Enforce max_history
    for len(session.history) > store.max_history {
        old := session.history[0]
        delete(old.role)
        delete(old.content)
        ordered_remove(&session.history, 0)
    }

    // Serialize and store to LMDB
    serialized := serialize_session_history(session)
    defer delete(serialized)
    store.mem.vtable.store(store.mem.ptr, key, transmute([]u8)serialized)

    // Update cache
    cloned_key := strings.clone(key)
    if existing, ok := &store.sessions[cloned_key]; ok {
        // Free old cached data
        for msg in existing.history {
            delete(msg.role)
            delete(msg.content)
        }
        delete(existing.history)
        delete(existing.session_id)
        delete(existing.channel)
        delete(existing.user_id)
    }
    store.sessions[cloned_key] = copy_session(session^)
}

// copy_session creates a deep copy of a session
copy_session :: proc(src: Session) -> Session {
    dst := Session{
        session_id  = strings.clone(src.session_id),
        channel     = strings.clone(src.channel),
        user_id     = strings.clone(src.user_id),
        history     = make([dynamic]Message, 0, len(src.history)),
        created_at  = src.created_at,
        last_active = src.last_active,
    }
    for msg in src.history {
        append(&dst.history, Message{
            role    = strings.clone(msg.role),
            content = strings.clone(msg.content),
        })
    }
    return dst
}

// cleanup_expired removes expired sessions
cleanup_expired_sessions :: proc(store: ^SessionStore) {
    now := time.time_to_unix(time.now())
    to_remove := make([dynamic]string)
    defer delete(to_remove)

    for key, session in store.sessions {
        if store.ttl_seconds > 0 && (now - session.last_active) > store.ttl_seconds {
            append(&to_remove, key)
        }
    }

    for key in to_remove {
        if session, ok := &store.sessions[key]; ok {
            delete(session.session_id)
            delete(session.channel)
            delete(session.user_id)
            for msg in session.history {
                delete(msg.role)
                delete(msg.content)
            }
            delete(session.history)
            delete_key(&store.sessions, key)
            store.mem.vtable.delete_key(store.mem.ptr, key)
        }
    }
}

// --- Serialization: simple JSON ---

serialize_session_history :: proc(session: ^Session) -> string {
    sb := strings.builder_make()

    strings.write_string(&sb, `{"last_active":`)
    strings.write_string(&sb, fmt.tprintf("%d", session.last_active))
    strings.write_string(&sb, `,"created_at":`)
    strings.write_string(&sb, fmt.tprintf("%d", session.created_at))
    strings.write_string(&sb, `,"messages":[`)

    for i := 0; i < len(session.history); i += 1 {
        if i > 0 {
            strings.write_string(&sb, ",")
        }
        msg := session.history[i]
        escaped_content := escape_json_string(msg.content)
        defer delete(escaped_content)
        strings.write_string(&sb, `{"role":"`)
        strings.write_string(&sb, msg.role)
        strings.write_string(&sb, `","content":"`)
        strings.write_string(&sb, escaped_content)
        strings.write_string(&sb, `"}`)
    }

    strings.write_string(&sb, `]}`)
    return strings.to_string(sb)
}

deserialize_session_history :: proc(session: ^Session, data: string) {
    // Parse last_active
    if la_idx := strings.index(data, `"last_active":`); la_idx >= 0 {
        pos := la_idx + len(`"last_active":`)
        end := pos
        for end < len(data) && data[end] >= '0' && data[end] <= '9' {
            end += 1
        }
        if end > pos {
            val := 0
            for i := pos; i < end; i += 1 {
                val = val * 10 + int(data[i] - '0')
            }
            session.last_active = i64(val)
        }
    }

    // Parse created_at
    if ca_idx := strings.index(data, `"created_at":`); ca_idx >= 0 {
        pos := ca_idx + len(`"created_at":`)
        end := pos
        for end < len(data) && data[end] >= '0' && data[end] <= '9' {
            end += 1
        }
        if end > pos {
            val := 0
            for i := pos; i < end; i += 1 {
                val = val * 10 + int(data[i] - '0')
            }
            session.created_at = i64(val)
        }
    }

    // Parse messages array
    msgs_idx := strings.index(data, `"messages":[`)
    if msgs_idx < 0 { return }
    pos := msgs_idx + len(`"messages":[`)

    for pos < len(data) {
        // Find next {"role":"
        role_start := strings.index(data[pos:], `"role":"`)
        if role_start < 0 { break }
        role_start += pos + len(`"role":"`)

        role_end := strings.index(data[role_start:], `"`)
        if role_end < 0 { break }
        role := data[role_start:role_start + role_end]

        // Find "content":"
        content_marker := strings.index(data[role_start:], `"content":"`)
        if content_marker < 0 { break }
        content_start := role_start + content_marker + len(`"content":"`)

        // Find end of content string (handle escapes)
        content_end := content_start
        for content_end < len(data) {
            if data[content_end] == '\\' && content_end + 1 < len(data) {
                content_end += 2
            } else if data[content_end] == '"' {
                break
            } else {
                content_end += 1
            }
        }

        content := data[content_start:content_end]
        append(&session.history, Message{
            role    = strings.clone(role),
            content = strings.clone(content),
        })

        pos = content_end + 1
    }
}
