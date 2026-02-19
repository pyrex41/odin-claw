package main

import "core:fmt"
import "core:strings"
import "core:mem"
import "core:testing"

Memory_Error :: enum {
    None,
    Key_Not_Found,
    Invalid_Data,
    Not_Implemented,
}



// Memory interface using vtable
Memory :: struct {
    ptr: rawptr,
    vtable: ^Memory_VTable,
}

Memory_VTable :: struct {
    store: proc(ptr: rawptr, key: string, data: []byte) -> Memory_Error,
    retrieve: proc(ptr: rawptr, key: string) -> ([]byte, Memory_Error),
    search: proc(ptr: rawptr, query: string) -> []string,
}

// In-Memory implementation
InMemoryMemory :: struct {
    data: map[string][]byte,
    allocator: mem.Allocator,
}

in_memory_vtable := Memory_VTable{
    store = in_memory_store,
    retrieve = in_memory_retrieve,
    search = in_memory_search,
}

init_in_memory :: proc(allocator := context.allocator) -> Memory {
    mem := new(InMemoryMemory, allocator)
    mem.data = make(map[string][]byte, allocator)
    mem.allocator = allocator
    return Memory{ptr = mem, vtable = &in_memory_vtable}
}

deinit_in_memory :: proc(mem: Memory) {
    impl := (^InMemoryMemory)(mem.ptr)
    for _, v in impl.data {
        delete(v, impl.allocator)
    }
    delete(impl.data)
    free(impl, impl.allocator)
}

in_memory_store :: proc(ptr: rawptr, key: string, data: []byte) -> Memory_Error {
    mem := (^InMemoryMemory)(ptr)
    // Clone the data
    cloned := make([]byte, len(data), mem.allocator)
    copy(cloned, data)
    mem.data[key] = cloned
    return .None
}

in_memory_retrieve :: proc(ptr: rawptr, key: string) -> ([]byte, Memory_Error) {
    mem := (^InMemoryMemory)(ptr)
    if data, ok := mem.data[key]; ok {
        // Return a copy
        cloned := make([]byte, len(data), mem.allocator)
        copy(cloned, data)
        return cloned, .None
    }
    return nil, .Key_Not_Found
}

in_memory_search :: proc(ptr: rawptr, query: string) -> []string {
    mem := (^InMemoryMemory)(ptr)
    results := make([dynamic]string, mem.allocator)
    for key, data in mem.data {
        text := string(data)
        if strings.contains(text, query) {
            append(&results, strings.clone(key, mem.allocator))
        }
    }
    return results[:]
}

// Placeholder for Embedding
Embedding :: struct {
    // Placeholder fields
    placeholder: int,
}

init_embedding :: proc() -> ^Embedding {
    // Placeholder implementation
    return new(Embedding)
}

deinit_embedding :: proc(emb: ^Embedding) {
    free(emb)
}

embed_text :: proc(emb: ^Embedding, text: string) -> []f32 {
    // Placeholder: return empty slice
    return nil
}

// Placeholder for SQLite
SQLiteMemory :: struct {
    // Placeholder fields
    db_path: string,
}

init_sqlite :: proc(db_path: string) -> ^SQLiteMemory {
    mem := new(SQLiteMemory)
    mem.db_path = strings.clone(db_path)
    return mem
}

deinit_sqlite :: proc(mem: ^SQLiteMemory) {
    delete(mem.db_path)
    free(mem)
}

store_sqlite :: proc(mem: ^SQLiteMemory, key: string, data: []byte) -> Memory_Error {
    // Placeholder: not implemented
    return .Not_Implemented
}

retrieve_sqlite :: proc(mem: ^SQLiteMemory, key: string) -> ([]byte, Memory_Error) {
    // Placeholder: not implemented
    return nil, .Not_Implemented
}

search_sqlite :: proc(mem: ^SQLiteMemory, query: string) -> []string {
    // Placeholder: not implemented
    return nil
}

// Tests
@test
test_in_memory_store_retrieve :: proc(t: ^testing.T) {
    mem := init_in_memory()
    defer deinit_in_memory(mem)

    key := "test_key"
    str := "test data"
    data := make([]u8, len(str))
    copy(data[:], str[:])
    defer delete(data)

    err := mem.vtable.store(mem.ptr, key, data)
    testing.expect(t, err == .None, "Store should succeed")

    retrieved, err2 := mem.vtable.retrieve(mem.ptr, key)
    testing.expect(t, err2 == .None, "Retrieve should succeed")
    testing.expect(t, len(retrieved) == len(data), "Data length should match")
    retrieved_str := string(retrieved)
    testing.expect(t, retrieved_str == str, "Data should match")

    delete(retrieved) // Since retrieve returns a copy, need to free
}

@test
test_in_memory_search :: proc(t: ^testing.T) {
    mem := init_in_memory()
    defer deinit_in_memory(mem)

    str1 := "hello world"
    data1 := make([]u8, len(str1))
    copy(data1[:], str1[:])
    mem.vtable.store(mem.ptr, "key1", data1)
    delete(data1)

    str2 := "foo bar"
    data2 := make([]u8, len(str2))
    copy(data2[:], str2[:])
    mem.vtable.store(mem.ptr, "key2", data2)
    delete(data2)

    str3 := "hello there"
    data3 := make([]u8, len(str3))
    copy(data3[:], str3[:])
    mem.vtable.store(mem.ptr, "key3", data3)
    delete(data3)

    results := mem.vtable.search(mem.ptr, "hello")
    testing.expect(t, len(results) == 2, "Should find 2 matches")
    // Sort or check contains
    found1, found3 := false, false
    for r in results {
        if r == "key1" { found1 = true }
        if r == "key3" { found3 = true }
        delete(r)
    }
    testing.expect(t, found1 && found3, "Should find key1 and key3")
    delete(results)
}

@test
test_retrieve_nonexistent :: proc(t: ^testing.T) {
    mem := init_in_memory()
    defer deinit_in_memory(mem)

    _, err := mem.vtable.retrieve(mem.ptr, "nonexistent")
    testing.expect(t, err == .Key_Not_Found, "Should return Key_Not_Found")
}