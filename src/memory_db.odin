package main

import "core:fmt"

FTS5Schema :: struct {
    table_name: string,
}

create_fts5_table :: proc(db: ^Db, table_name: string, columns: []string) -> bool {
    // Create FTS5 virtual table for full-text search
    // FTS5 provides fast keyword search without loading all data into memory
    return true
}

search_fts5 :: proc(db: ^Db, table_name: string, query: string, limit: int) -> []string {
    // Search the FTS5 table and return matching row keys
    return make([]string, 0)
}

MemorySchema :: struct {
    messages_table: string,
    embeddings_table: string,
    fts_table: string,
}

create_memory_schema :: proc(db: ^Db) -> bool {
    // Messages table
    // CREATE TABLE IF NOT EXISTS messages (
    //     id INTEGER PRIMARY KEY AUTOINCREMENT,
    //     session_id TEXT NOT NULL,
    //     role TEXT NOT NULL,
    //     content TEXT NOT NULL,
    //     created_at INTEGER NOT NULL
    // );
    
    // Embeddings table
    // CREATE TABLE IF NOT EXISTS embeddings (
    //     id INTEGER PRIMARY KEY AUTOINCREMENT,
    //     message_id INTEGER NOT NULL,
    //     vector BLOB NOT NULL,
    //     FOREIGN KEY (message_id) REFERENCES messages(id)
    // );
    
    // FTS5 virtual table for full-text search
    // CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    //     content,
    //     content='messages',
    //     content_rowid='id'
    // );
    
    // Triggers to keep FTS in sync
    // CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    //     INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
    // END;
    
    return true
}

Db :: struct {
    // Placeholder for SQLite database connection
    // In full implementation, this would hold the sqlite3* pointer
    path: string,
    connected: bool,
}

init_db :: proc(path: string) -> ^Db {
    db := new(Db)
    db.path = path
    db.connected = false
    return db
}

deinit_db :: proc(db: ^Db) {
    free(db)
}
