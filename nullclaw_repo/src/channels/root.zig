//! Channels — messaging platform integrations.
//! Each channel implements the Channel interface (vtable-based polymorphism).
//!
//! Channels (matching ZeroClaw):
//!   - CLI (built-in stdin/stdout)
//!   - Telegram (long-polling)
//!   - Discord (WebSocket gateway)
//!   - Slack (polling conversations.history)
//!   - WhatsApp (webhook-based)
//!   - Matrix (long-polling /sync)
//!   - IRC (TLS socket)
//!   - iMessage (AppleScript + SQLite on macOS)
//!   - Email (IMAP/SMTP)
//!   - Lark/Feishu (HTTP callback)
//!   - DingTalk (WebSocket stream mode)

const std = @import("std");

// ════════════════════════════════════════════════════════════════════════════
// Shared Types
// ════════════════════════════════════════════════════════════════════════════

/// A message received from or sent to a channel.
pub const ChannelMessage = struct {
    id: []const u8,
    sender: []const u8,
    content: []const u8,
    channel: []const u8,
    timestamp: u64,
    /// Where to send a reply (e.g., DM sender vs channel name in IRC, thread ID in Telegram).
    reply_target: ?[]const u8 = null,
    /// Platform message ID (e.g. Telegram message_id for reply-to).
    message_id: ?i64 = null,
    /// Sender's first name (for personalized greetings).
    first_name: ?[]const u8 = null,
    /// Whether the message came from a group chat.
    is_group: bool = false,

    pub fn deinit(self: *const ChannelMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.sender);
        allocator.free(self.content);
        // channel is a string literal or long-lived config pointer — not owned, don't free
        if (self.reply_target) |rt| allocator.free(rt);
        if (self.first_name) |fn_| allocator.free(fn_);
    }
};

/// Channel interface — Zig equivalent of ZeroClaw's Channel trait.
/// Uses vtable-based polymorphism for runtime dispatch.
pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Start the channel (connect, begin listening).
        start: *const fn (ptr: *anyopaque) anyerror!void,
        /// Stop the channel (disconnect, clean up).
        stop: *const fn (ptr: *anyopaque) void,
        /// Send a message to a target (user, channel, room, etc.).