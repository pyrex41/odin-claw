package main

import "core:strings"
import "core:testing"

// Tests for memory functionality

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