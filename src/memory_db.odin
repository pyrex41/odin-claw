package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

// LMDB-backed memory subsystem
// Uses key prefixes to organize different data types within a single LMDB env:
//   "k:" — knowledge entries (serialized JSON)
//   "m:" — messages by session (serialized JSON)
//   "e:" — embedding vectors (raw f32 bytes)

// ============================================================================
// Memory Categories (matches NullClaw's MemoryCategory)
// ============================================================================

MemoryCategory :: enum {
    Core,          // Critical long-term knowledge
    Daily,         // Daily facts/summaries
    Conversation,  // Session-specific context
    Custom,        // User-defined
}

memory_category_string :: proc(cat: MemoryCategory) -> string {
    switch cat {
    case .Core:         return "core"
    case .Daily:        return "daily"
    case .Conversation: return "conversation"
    case .Custom:       return "custom"
    }
    return "core"
}

parse_memory_category :: proc(s: string) -> MemoryCategory {
    if s == "daily"        { return .Daily }
    if s == "conversation" { return .Conversation }
    if s == "custom"       { return .Custom }
    return .Core
}

// ============================================================================
// Knowledge Entry
// ============================================================================

KnowledgeEntry :: struct {
    key:          string,
    value:        string,
    category:     MemoryCategory,
    session_id:   string,
    created_at:   i64,
    updated_at:   i64,
}

// Serialize a KnowledgeEntry to JSON for storage in LMDB
serialize_knowledge :: proc(entry: ^KnowledgeEntry) -> string {
    sb := strings.builder_make()

    escaped_key := escape_json_string(entry.key)
    defer delete(escaped_key)
    escaped_value := escape_json_string(entry.value)
    defer delete(escaped_value)
    escaped_sid := escape_json_string(entry.session_id)
    defer delete(escaped_sid)

    strings.write_string(&sb, `{"key":"`)
    strings.write_string(&sb, escaped_key)
    strings.write_string(&sb, `","value":"`)
    strings.write_string(&sb, escaped_value)
    strings.write_string(&sb, `","category":"`)
    strings.write_string(&sb, memory_category_string(entry.category))
    strings.write_string(&sb, `","session_id":"`)
    strings.write_string(&sb, escaped_sid)
    strings.write_string(&sb, `","created_at":`)
    strings.write_string(&sb, fmt.tprintf("%d", entry.created_at))
    strings.write_string(&sb, `,"updated_at":`)
    strings.write_string(&sb, fmt.tprintf("%d", entry.updated_at))
    strings.write_string(&sb, `}`)

    return strings.to_string(sb)
}

// Deserialize a KnowledgeEntry from JSON
deserialize_knowledge :: proc(data: string) -> (KnowledgeEntry, bool) {
    entry: KnowledgeEntry

    key_val := extract_json_string(data, "key")
    if key_val == "" { return {}, false }
    entry.key = strings.clone(key_val)

    val_val := extract_json_string(data, "value")
    entry.value = strings.clone(val_val)

    cat_val := extract_json_string(data, "category")
    entry.category = parse_memory_category(cat_val)

    sid_val := extract_json_string(data, "session_id")
    entry.session_id = strings.clone(sid_val)

    entry.created_at = parse_json_i64(data, "created_at")
    entry.updated_at = parse_json_i64(data, "updated_at")

    return entry, true
}

free_knowledge_entry :: proc(entry: ^KnowledgeEntry) {
    delete(entry.key)
    delete(entry.value)
    delete(entry.session_id)
}

// ============================================================================
// Message Record
// ============================================================================

MemoryRecord :: struct {
    session_id: string,
    role:       string,
    content:    string,
    created_at: i64,
}

// ============================================================================
// LMDB Knowledge Store
// ============================================================================

// store_knowledge stores or updates a knowledge entry in LMDB.
// Key format: "k:{key}"
store_knowledge :: proc(mem: Memory, key: string, value: string, category: MemoryCategory, session_id: string) -> bool {
    now := time.time_to_unix(time.now())

    // Check if entry already exists to preserve created_at
    created_at := now
    lmdb_key := fmt.tprintf("k:%s", key)
    existing_data, err := mem.vtable.retrieve(mem.ptr, lmdb_key)
    if err == .None && len(existing_data) > 0 {
        existing, ok := deserialize_knowledge(string(existing_data))
        if ok {
            created_at = existing.created_at
            free_knowledge_entry(&existing)
        }
        delete(existing_data)
    }

    entry := KnowledgeEntry{
        key        = key,
        value      = value,
        category   = category,
        session_id = session_id,
        created_at = created_at,
        updated_at = now,
    }

    serialized := serialize_knowledge(&entry)
    defer delete(serialized)

    store_err := mem.vtable.store(mem.ptr, lmdb_key, transmute([]u8)serialized)
    return store_err == .None
}

// get_knowledge retrieves a knowledge entry by key from LMDB
get_knowledge :: proc(mem: Memory, key: string) -> (KnowledgeEntry, bool) {
    lmdb_key := fmt.tprintf("k:%s", key)
    data, err := mem.vtable.retrieve(mem.ptr, lmdb_key)
    if err != .None { return {}, false }
    defer delete(data)

    return deserialize_knowledge(string(data))
}

// delete_knowledge removes a knowledge entry from LMDB
delete_knowledge :: proc(mem: Memory, key: string) -> bool {
    lmdb_key := fmt.tprintf("k:%s", key)
    return mem.vtable.delete_key(mem.ptr, lmdb_key) == .None
}

// search_knowledge scans all "k:" prefixed keys and returns entries
// whose key or value contain the query string.
search_knowledge :: proc(mem: Memory, query: string, limit: int) -> []KnowledgeEntry {
    if query == "" { return nil }

    // Use LMDB cursor search with "k:" prefix — the Memory.search does
    // substring matching on values. We search for the query across all entries.
    matching_keys := mem.vtable.search(mem.ptr, query)
    if matching_keys == nil { return nil }
    defer {
        for k in matching_keys { delete(k) }
        delete(matching_keys)
    }

    results := make([dynamic]KnowledgeEntry)
    count := 0
    for k in matching_keys {
        if limit > 0 && count >= limit { break }
        // Only process knowledge keys
        if len(k) < 2 || k[0] != 'k' || k[1] != ':' { continue }

        actual_key := k[2:]
        entry, ok := get_knowledge(mem, actual_key)
        if ok {
            append(&results, entry)
            count += 1
        }
    }
    return results[:]
}

// list_knowledge_by_category scans all knowledge entries and filters by category.
list_knowledge_by_category :: proc(mem: Memory, category: MemoryCategory) -> []KnowledgeEntry {
    // Search with empty-ish query to get all keys — use the category string
    // as a search term since it appears in serialized values
    cat_str := memory_category_string(category)
    matching_keys := mem.vtable.search(mem.ptr, cat_str)
    if matching_keys == nil { return nil }
    defer {
        for k in matching_keys { delete(k) }
        delete(matching_keys)
    }

    results := make([dynamic]KnowledgeEntry)
    for k in matching_keys {
        if len(k) < 2 || k[0] != 'k' || k[1] != ':' { continue }

        actual_key := k[2:]
        entry, ok := get_knowledge(mem, actual_key)
        if ok {
            if entry.category == category {
                append(&results, entry)
            } else {
                free_knowledge_entry(&entry)
            }
        }
    }
    return results[:]
}

// hygiene_memory removes old entries below importance threshold.
// Since LMDB doesn't have an importance field natively, we scan all
// knowledge entries and remove those older than max_age_days.
hygiene_memory :: proc(mem: Memory, max_age_days: int) -> int {
    now := time.time_to_unix(time.now())
    cutoff := now - i64(max_age_days * 86400)

    // Scan all knowledge entries via a broad search
    // We use a space character which should match most entries
    all_keys := mem.vtable.search(mem.ptr, " ")
    if all_keys == nil { return 0 }
    defer {
        for k in all_keys { delete(k) }
        delete(all_keys)
    }

    removed := 0
    for k in all_keys {
        if len(k) < 2 || k[0] != 'k' || k[1] != ':' { continue }

        actual_key := k[2:]
        entry, ok := get_knowledge(mem, actual_key)
        if !ok { continue }

        if entry.updated_at < cutoff && entry.category != .Core {
            delete_knowledge(mem, actual_key)
            removed += 1
        }
        free_knowledge_entry(&entry)
    }

    fmt.printf("[Memory] Hygiene: removed %d entries older than %d days\n", removed, max_age_days)
    return removed
}

// ============================================================================
// LMDB Message Storage
// ============================================================================

// store_message stores a message in LMDB.
// Key format: "m:{session_id}:{timestamp}:{index}"
store_message :: proc(mem: Memory, session_id: string, role: string, content: string) -> bool {
    now := time.time_to_unix(time.now())

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    escaped_content := escape_json_string(content)
    defer delete(escaped_content)

    strings.write_string(&sb, `{"session_id":"`)
    strings.write_string(&sb, session_id)
    strings.write_string(&sb, `","role":"`)
    strings.write_string(&sb, role)
    strings.write_string(&sb, `","content":"`)
    strings.write_string(&sb, escaped_content)
    strings.write_string(&sb, `","created_at":`)
    strings.write_string(&sb, fmt.tprintf("%d", now))
    strings.write_string(&sb, `}`)

    serialized := strings.to_string(sb)
    lmdb_key := fmt.tprintf("m:%s:%d", session_id, now)

    return mem.vtable.store(mem.ptr, lmdb_key, transmute([]u8)serialized) == .None
}

// search_messages scans all "m:" prefixed keys matching the query
search_messages :: proc(mem: Memory, query: string, limit: int) -> []MemoryRecord {
    matching_keys := mem.vtable.search(mem.ptr, query)
    if matching_keys == nil { return nil }
    defer {
        for k in matching_keys { delete(k) }
        delete(matching_keys)
    }

    results := make([dynamic]MemoryRecord)
    count := 0
    for k in matching_keys {
        if limit > 0 && count >= limit { break }
        if len(k) < 2 || k[0] != 'm' || k[1] != ':' { continue }

        data, err := mem.vtable.retrieve(mem.ptr, k)
        if err != .None { continue }
        defer delete(data)

        record := MemoryRecord{
            session_id = strings.clone(extract_json_string(string(data), "session_id")),
            role       = strings.clone(extract_json_string(string(data), "role")),
            content    = strings.clone(extract_json_string(string(data), "content")),
            created_at = parse_json_i64(string(data), "created_at"),
        }
        append(&results, record)
        count += 1
    }
    return results[:]
}

// ============================================================================
// Vector Embedding Support
// ============================================================================

EmbeddingProvider :: enum {
    OpenAI, // text-embedding-3-small
    Local,  // Local model
}

// Embedding represents a text embedding vector
Embedding :: struct {
    dimensions: int,
    values:     []f32,
}

init_embedding :: proc() -> ^Embedding {
    emb := new(Embedding)
    emb.dimensions = 1536 // OpenAI default
    return emb
}

deinit_embedding :: proc(emb: ^Embedding) {
    if emb.values != nil {
        delete(emb.values)
    }
    free(emb)
}

// embed_text generates an embedding for the given text (placeholder for API call)
embed_text :: proc(emb: ^Embedding, text: string) -> []f32 {
    // In a full implementation, call the OpenAI embedding API:
    // POST https://api.openai.com/v1/embeddings
    // {"input": "text", "model": "text-embedding-3-small"}
    return nil
}

// store_embedding stores an embedding vector in LMDB.
// Key format: "e:{key}"
store_embedding :: proc(mem: Memory, key: string, values: []f32) -> bool {
    lmdb_key := fmt.tprintf("e:%s", key)
    // Store raw f32 bytes
    byte_len := len(values) * size_of(f32)
    raw := ([^]byte)(raw_data(values))[:byte_len]
    return mem.vtable.store(mem.ptr, lmdb_key, raw) == .None
}

// retrieve_embedding loads an embedding vector from LMDB
retrieve_embedding :: proc(mem: Memory, key: string) -> ([]f32, bool) {
    lmdb_key := fmt.tprintf("e:%s", key)
    data, err := mem.vtable.retrieve(mem.ptr, lmdb_key)
    if err != .None { return nil, false }

    num_floats := len(data) / size_of(f32)
    if num_floats == 0 {
        delete(data)
        return nil, false
    }

    // Reinterpret the byte slice as f32 slice
    result := make([]f32, num_floats)
    src := ([^]f32)(raw_data(data))
    for i := 0; i < num_floats; i += 1 {
        result[i] = src[i]
    }
    delete(data)
    return result, true
}

// cosine_similarity computes similarity between two embedding vectors
cosine_similarity :: proc(a: []f32, b: []f32) -> f32 {
    if len(a) != len(b) || len(a) == 0 {
        return 0
    }

    dot_product: f32 = 0
    norm_a: f32 = 0
    norm_b: f32 = 0

    for i := 0; i < len(a); i += 1 {
        dot_product += a[i] * b[i]
        norm_a += a[i] * a[i]
        norm_b += b[i] * b[i]
    }

    if norm_a == 0 || norm_b == 0 {
        return 0
    }

    magnitude := math.sqrt(norm_a) * math.sqrt(norm_b)
    if magnitude == 0 { return 0 }
    return dot_product / magnitude
}

SimilarityResult :: struct {
    key:        string,
    similarity: f32,
}

// find_similar scans all stored embeddings and returns the top-k most similar
find_similar :: proc(mem: Memory, query_embedding: []f32, top_k: int) -> []SimilarityResult {

    // Get all embedding keys by searching for any content in "e:" space
    all_keys := mem.vtable.search(mem.ptr, "")
    if all_keys == nil { return nil }
    defer {
        for k in all_keys { delete(k) }
        delete(all_keys)
    }

    results := make([dynamic]SimilarityResult)
    for k in all_keys {
        if len(k) < 2 || k[0] != 'e' || k[1] != ':' { continue }
        actual_key := k[2:]

        emb, ok := retrieve_embedding(mem, actual_key)
        if !ok { continue }
        defer delete(emb)

        sim := cosine_similarity(query_embedding, emb)
        append(&results, SimilarityResult{key = strings.clone(actual_key), similarity = sim})
    }

    // Simple selection sort for top-k
    for i := 0; i < min(top_k, len(results)); i += 1 {
        best := i
        for j := i + 1; j < len(results); j += 1 {
            if results[j].similarity > results[best].similarity {
                best = j
            }
        }
        if best != i {
            results[i], results[best] = results[best], results[i]
        }
    }

    n := min(top_k, len(results))
    // Free unused results
    for i := n; i < len(results); i += 1 {
        delete(results[i].key)
    }

    // Shrink to top_k
    result_slice := make([]SimilarityResult, n)
    for i := 0; i < n; i += 1 {
        result_slice[i] = results[i]
    }
    delete(results)
    return result_slice
}

// ============================================================================
// JSON helpers (internal)
// ============================================================================

parse_json_i64 :: proc(data: string, field: string) -> i64 {
    search := fmt.tprintf(`"%s":`, field)
    idx := strings.index(data, search)
    if idx < 0 { return 0 }

    pos := idx + len(search)
    // Skip whitespace
    for pos < len(data) && (data[pos] == ' ' || data[pos] == '\t') {
        pos += 1
    }

    val: i64 = 0
    neg := false
    if pos < len(data) && data[pos] == '-' {
        neg = true
        pos += 1
    }
    for pos < len(data) && data[pos] >= '0' && data[pos] <= '9' {
        val = val * 10 + i64(data[pos] - '0')
        pos += 1
    }
    if neg { val = -val }
    return val
}
