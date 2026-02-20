package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// --- LMDB FFI bindings ---

MDB_env :: distinct rawptr
MDB_txn :: distinct rawptr
MDB_cursor :: distinct rawptr
MDB_dbi :: distinct u32

MDB_val :: struct {
    mv_size: uint,
    mv_data: rawptr,
}

MDB_cursor_op :: enum i32 {
    MDB_FIRST    = 0,
    MDB_NEXT     = 8,
    MDB_SET      = 16,
    MDB_SET_RANGE = 17,
    MDB_LAST     = 6,
}

MDB_SUCCESS  :: 0
MDB_NOTFOUND :: -30798
MDB_CREATE   :: 0x40000
MDB_RDONLY   :: 0x20000

@(extra_linker_flags = "-L/opt/homebrew/lib")
foreign import liblmdb "system:lmdb"

foreign liblmdb {
    mdb_env_create   :: proc(env: ^MDB_env) -> i32 ---
    mdb_env_open     :: proc(env: MDB_env, path: cstring, flags: u32, mode: u32) -> i32 ---
    mdb_env_set_mapsize :: proc(env: MDB_env, size: uint) -> i32 ---
    mdb_env_close    :: proc(env: MDB_env) ---
    mdb_txn_begin    :: proc(env: MDB_env, parent: MDB_txn, flags: u32, txn: ^MDB_txn) -> i32 ---
    mdb_txn_commit   :: proc(txn: MDB_txn) -> i32 ---
    mdb_txn_abort    :: proc(txn: MDB_txn) ---
    mdb_dbi_open     :: proc(txn: MDB_txn, name: cstring, flags: u32, dbi: ^MDB_dbi) -> i32 ---
    mdb_put          :: proc(txn: MDB_txn, dbi: MDB_dbi, key: ^MDB_val, data: ^MDB_val, flags: u32) -> i32 ---
    mdb_get          :: proc(txn: MDB_txn, dbi: MDB_dbi, key: ^MDB_val, data: ^MDB_val) -> i32 ---
    mdb_del          :: proc(txn: MDB_txn, dbi: MDB_dbi, key: ^MDB_val, data: ^MDB_val) -> i32 ---
    mdb_cursor_open  :: proc(txn: MDB_txn, dbi: MDB_dbi, cursor: ^MDB_cursor) -> i32 ---
    mdb_cursor_get   :: proc(cursor: MDB_cursor, key: ^MDB_val, data: ^MDB_val, op: MDB_cursor_op) -> i32 ---
    mdb_cursor_close :: proc(cursor: MDB_cursor) ---
    mdb_strerror     :: proc(err: i32) -> cstring ---
}

// --- LMDBMemory implementation ---

LMDBMemory :: struct {
    env: MDB_env,
    dbi: MDB_dbi,
}

lmdb_vtable := Memory_VTable{
    store      = lmdb_store,
    retrieve   = lmdb_retrieve,
    search     = lmdb_search,
    delete_key = lmdb_delete_key,
}

init_lmdb_memory :: proc(path: string, map_size: uint = 256 * 1024 * 1024) -> (Memory, bool) {
    impl := new(LMDBMemory)

    rc := mdb_env_create(&impl.env)
    if rc != MDB_SUCCESS {
        free(impl)
        return {}, false
    }

    rc = mdb_env_set_mapsize(impl.env, map_size)
    if rc != MDB_SUCCESS {
        mdb_env_close(impl.env)
        free(impl)
        return {}, false
    }

    cpath := strings.clone_to_cstring(path)
    defer delete(cpath)

    // Create directory if it doesn't exist
    os.make_directory(path)

    rc = mdb_env_open(impl.env, cpath, 0, 0o644)
    if rc != MDB_SUCCESS {
        mdb_env_close(impl.env)
        free(impl)
        return {}, false
    }

    // Open the default database in an initial transaction
    txn: MDB_txn
    rc = mdb_txn_begin(impl.env, nil, 0, &txn)
    if rc != MDB_SUCCESS {
        mdb_env_close(impl.env)
        free(impl)
        return {}, false
    }

    rc = mdb_dbi_open(txn, nil, MDB_CREATE, &impl.dbi)
    if rc != MDB_SUCCESS {
        mdb_txn_abort(txn)
        mdb_env_close(impl.env)
        free(impl)
        return {}, false
    }

    rc = mdb_txn_commit(txn)
    if rc != MDB_SUCCESS {
        mdb_env_close(impl.env)
        free(impl)
        return {}, false
    }

    return Memory{ptr = impl, vtable = &lmdb_vtable}, true
}

deinit_lmdb_memory :: proc(mem: Memory) {
    if mem.ptr == nil { return }
    impl := (^LMDBMemory)(mem.ptr)
    mdb_env_close(impl.env)
    free(impl)
}

lmdb_store :: proc(ptr: rawptr, key: string, data: []byte) -> Memory_Error {
    impl := (^LMDBMemory)(ptr)

    txn: MDB_txn
    rc := mdb_txn_begin(impl.env, nil, 0, &txn)
    if rc != MDB_SUCCESS { return .Invalid_Data }

    k := MDB_val{mv_size = len(key), mv_data = raw_data(key)}
    v := MDB_val{mv_size = len(data), mv_data = raw_data(data)}

    rc = mdb_put(txn, impl.dbi, &k, &v, 0)
    if rc != MDB_SUCCESS {
        mdb_txn_abort(txn)
        return .Invalid_Data
    }

    rc = mdb_txn_commit(txn)
    if rc != MDB_SUCCESS { return .Invalid_Data }

    return .None
}

lmdb_retrieve :: proc(ptr: rawptr, key: string) -> ([]byte, Memory_Error) {
    impl := (^LMDBMemory)(ptr)

    txn: MDB_txn
    rc := mdb_txn_begin(impl.env, nil, MDB_RDONLY, &txn)
    if rc != MDB_SUCCESS { return nil, .Invalid_Data }

    k := MDB_val{mv_size = len(key), mv_data = raw_data(key)}
    v: MDB_val

    rc = mdb_get(txn, impl.dbi, &k, &v)
    if rc == MDB_NOTFOUND {
        mdb_txn_abort(txn)
        return nil, .Key_Not_Found
    }
    if rc != MDB_SUCCESS {
        mdb_txn_abort(txn)
        return nil, .Invalid_Data
    }

    // Copy data out — mdb_get returns a pointer into the mmap, only valid during txn
    result := make([]byte, v.mv_size)
    src := ([^]byte)(v.mv_data)
    for i in 0 ..< v.mv_size {
        result[i] = src[i]
    }

    mdb_txn_abort(txn)
    return result, .None
}

lmdb_search :: proc(ptr: rawptr, query: string) -> []string {
    impl := (^LMDBMemory)(ptr)
    results := make([dynamic]string)

    txn: MDB_txn
    rc := mdb_txn_begin(impl.env, nil, MDB_RDONLY, &txn)
    if rc != MDB_SUCCESS { return results[:] }

    cursor: MDB_cursor
    rc = mdb_cursor_open(txn, impl.dbi, &cursor)
    if rc != MDB_SUCCESS {
        mdb_txn_abort(txn)
        return results[:]
    }

    k: MDB_val
    v: MDB_val
    rc = mdb_cursor_get(cursor, &k, &v, .MDB_FIRST)
    for rc == MDB_SUCCESS {
        // Check if value contains the query
        val_bytes := ([^]byte)(v.mv_data)[:v.mv_size]
        if strings.contains(string(val_bytes), query) {
            key_bytes := ([^]byte)(k.mv_data)[:k.mv_size]
            append(&results, strings.clone(string(key_bytes)))
        }
        rc = mdb_cursor_get(cursor, &k, &v, .MDB_NEXT)
    }

    mdb_cursor_close(cursor)
    mdb_txn_abort(txn)
    return results[:]
}

lmdb_delete_key :: proc(ptr: rawptr, key: string) -> Memory_Error {
    impl := (^LMDBMemory)(ptr)

    txn: MDB_txn
    rc := mdb_txn_begin(impl.env, nil, 0, &txn)
    if rc != MDB_SUCCESS { return .Invalid_Data }

    k := MDB_val{mv_size = len(key), mv_data = raw_data(key)}

    rc = mdb_del(txn, impl.dbi, &k, nil)
    if rc == MDB_NOTFOUND {
        mdb_txn_abort(txn)
        return .Key_Not_Found
    }
    if rc != MDB_SUCCESS {
        mdb_txn_abort(txn)
        return .Invalid_Data
    }

    rc = mdb_txn_commit(txn)
    if rc != MDB_SUCCESS { return .Invalid_Data }

    return .None
}

// --- Migration helper ---

Snapshot_Entry :: struct {
    key:   string,
    value: string,
}

Snapshot :: struct {
    version: int,
    entries: []Snapshot_Entry,
}

// migrate_snapshot_to_lmdb imports a JSON snapshot file into an LMDB memory store
migrate_snapshot_to_lmdb :: proc(lmdb_mem: Memory, snapshot_path: string) -> bool {
    data, ok := os.read_entire_file(snapshot_path)
    if !ok { return false }
    defer delete(data)

    snapshot: Snapshot
    err := json.unmarshal(data, &snapshot)
    if err != nil { return false }

    for entry in snapshot.entries {
        lmdb_mem.vtable.store(lmdb_mem.ptr, entry.key, transmute([]u8)entry.value)
    }

    return true
}

// --- Tests ---

@(test)
test_lmdb_store_retrieve :: proc(t: ^testing.T) {
    test_path := "/tmp/nullclaw_test_lmdb_sr"
    defer {
        os.remove(fmt.tprintf("%s/data.mdb", test_path))
        os.remove(fmt.tprintf("%s/lock.mdb", test_path))
        os.remove(test_path)
    }

    mem, ok := init_lmdb_memory(test_path)
    testing.expect(t, ok, "LMDB init should succeed")
    defer deinit_lmdb_memory(mem)

    key := "test_key"
    value := "hello lmdb"
    err := mem.vtable.store(mem.ptr, key, transmute([]u8)value)
    testing.expect(t, err == .None, "Store should succeed")

    retrieved, err2 := mem.vtable.retrieve(mem.ptr, key)
    testing.expect(t, err2 == .None, "Retrieve should succeed")
    testing.expect(t, string(retrieved) == value, "Retrieved value should match")
    delete(retrieved)

    _, err3 := mem.vtable.retrieve(mem.ptr, "nonexistent")
    testing.expect(t, err3 == .Key_Not_Found, "Missing key should return Key_Not_Found")
}

@(test)
test_lmdb_search :: proc(t: ^testing.T) {
    test_path := "/tmp/nullclaw_test_lmdb_search"
    defer {
        os.remove(fmt.tprintf("%s/data.mdb", test_path))
        os.remove(fmt.tprintf("%s/lock.mdb", test_path))
        os.remove(test_path)
    }

    mem, ok := init_lmdb_memory(test_path)
    testing.expect(t, ok, "LMDB init should succeed")
    defer deinit_lmdb_memory(mem)

    mem.vtable.store(mem.ptr, "greeting", transmute([]u8)string("hello world"))
    mem.vtable.store(mem.ptr, "farewell", transmute([]u8)string("goodbye world"))
    mem.vtable.store(mem.ptr, "other", transmute([]u8)string("something else"))

    results := mem.vtable.search(mem.ptr, "world")
    testing.expect(t, len(results) == 2, "Should find 2 matches")
    for r in results { delete(r) }
    delete(results)
}

@(test)
test_lmdb_delete :: proc(t: ^testing.T) {
    test_path := "/tmp/nullclaw_test_lmdb_del"
    defer {
        os.remove(fmt.tprintf("%s/data.mdb", test_path))
        os.remove(fmt.tprintf("%s/lock.mdb", test_path))
        os.remove(test_path)
    }

    mem, ok := init_lmdb_memory(test_path)
    testing.expect(t, ok, "LMDB init should succeed")
    defer deinit_lmdb_memory(mem)

    mem.vtable.store(mem.ptr, "to_delete", transmute([]u8)string("some data"))

    err := mem.vtable.delete_key(mem.ptr, "to_delete")
    testing.expect(t, err == .None, "Delete should succeed")

    _, err2 := mem.vtable.retrieve(mem.ptr, "to_delete")
    testing.expect(t, err2 == .Key_Not_Found, "Deleted key should not be found")

    err3 := mem.vtable.delete_key(mem.ptr, "nonexistent")
    testing.expect(t, err3 == .Key_Not_Found, "Deleting nonexistent key should return Key_Not_Found")
}
