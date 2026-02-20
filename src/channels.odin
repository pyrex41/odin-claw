package main

import "core:fmt"
import "core:strings"

Channel_Error :: enum {
    None,
    Not_Configured,
    Connection_Failed,
    Send_Failed,
    Receive_Failed,
}

Channel_VTable :: struct {
    send: proc(ptr: rawptr, message: string) -> Channel_Error,
    receive: proc(ptr: rawptr) -> (string, Channel_Error),
    name: proc(ptr: rawptr) -> string,
    is_configured: proc(ptr: rawptr) -> bool,
    deinit: proc(ptr: rawptr),
}

Channel :: struct {
    ptr: rawptr,
    vtable: ^Channel_VTable,
}

ChannelMessage :: struct {
    sender: string,
    content: string,
    channel: string,
    timestamp: i64,
}

send_message :: proc(ch: Channel, message: string) -> Channel_Error {
    return ch.vtable.send(ch.ptr, message)
}

receive_message :: proc(ch: Channel) -> (string, Channel_Error) {
    return ch.vtable.receive(ch.ptr)
}

channel_name :: proc(ch: Channel) -> string {
    return ch.vtable.name(ch.ptr)
}

is_channel_configured :: proc(ch: Channel) -> bool {
    return ch.vtable.is_configured(ch.ptr)
}

deinit_channel :: proc(ch: Channel) {
    ch.vtable.deinit(ch.ptr)
}

SlackChannel :: struct {
    webhook_url: string,
    bot_token: string,
    channel_id: string,
}

init_slack_channel :: proc(webhook_url: string, bot_token: string, channel_id: string) -> Channel {
    sc := new(SlackChannel)
    sc.webhook_url = webhook_url
    sc.bot_token = bot_token
    sc.channel_id = channel_id
    return Channel{ptr = sc, vtable = &slack_vtable}
}

slack_vtable := Channel_VTable{
    send = slack_send,
    receive = slack_receive,
    name = slack_name,
    is_configured = slack_is_configured,
    deinit = slack_deinit,
}

slack_send :: proc(ptr: rawptr, message: string) -> Channel_Error {
    sc := (^SlackChannel)(ptr)
    if sc.webhook_url == "" {
        return .Not_Configured
    }

    escaped := escape_json_string(message)
    defer delete(escaped)

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"text":"`)
    strings.write_string(&sb, escaped)
    strings.write_string(&sb, `"}`)
    body := strings.clone(strings.to_string(sb))
    defer delete(body)

    headers := []string{"Content-Type: application/json"}
    resp, err := http_post_request(sc.webhook_url, body, headers)
    if err != .None {
        fmt.printf("[Slack] Send failed: %v\n", err)
        return .Send_Failed
    }
    defer delete(resp.body)

    if resp.status_code < 200 || resp.status_code >= 300 {
        fmt.printf("[Slack] Send failed: status=%d\n", resp.status_code)
        return .Send_Failed
    }

    fmt.printf("[Slack] Message sent (status=%d)\n", resp.status_code)
    return .None
}

slack_receive :: proc(ptr: rawptr) -> (string, Channel_Error) {
    sc := (^SlackChannel)(ptr)
    if sc.webhook_url == "" {
        return "", .Not_Configured
    }
    
    return "", .Not_Configured
}

slack_name :: proc(ptr: rawptr) -> string {
    return "slack"
}

slack_is_configured :: proc(ptr: rawptr) -> bool {
    sc := (^SlackChannel)(ptr)
    return sc.webhook_url != "" || sc.bot_token != ""
}

slack_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

TelegramChannel :: struct {
    bot_token: string,
    api_url: string,
    default_chat_id: string,
}

init_telegram_channel :: proc(bot_token: string) -> Channel {
    tc := new(TelegramChannel)
    tc.bot_token = bot_token
    tc.api_url = "https://api.telegram.org"
    return Channel{ptr = tc, vtable = &telegram_vtable}
}

telegram_vtable := Channel_VTable{
    send = telegram_send,
    receive = telegram_receive,
    name = telegram_name,
    is_configured = telegram_is_configured,
    deinit = telegram_deinit,
}

telegram_send :: proc(ptr: rawptr, message: string) -> Channel_Error {
    tc := (^TelegramChannel)(ptr)
    if tc.bot_token == "" {
        return .Not_Configured
    }
    if tc.default_chat_id == "" {
        return .Not_Configured
    }

    url := fmt.tprintf("https://api.telegram.org/bot%s/sendMessage", tc.bot_token)
    escaped := escape_json_string(message)
    defer delete(escaped)

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"chat_id":"`)
    strings.write_string(&sb, tc.default_chat_id)
    strings.write_string(&sb, `","text":"`)
    strings.write_string(&sb, escaped)
    strings.write_string(&sb, `"}`)
    body := strings.clone(strings.to_string(sb))
    defer delete(body)

    headers := []string{"Content-Type: application/json"}
    resp, err := http_post_request(url, body, headers)
    if err != .None {
        fmt.printf("[Telegram] Send failed: %v\n", err)
        return .Send_Failed
    }
    defer delete(resp.body)

    if resp.status_code < 200 || resp.status_code >= 300 {
        fmt.printf("[Telegram] Send failed: status=%d\n", resp.status_code)
        return .Send_Failed
    }

    fmt.printf("[Telegram] Message sent (status=%d)\n", resp.status_code)
    return .None
}

telegram_receive :: proc(ptr: rawptr) -> (string, Channel_Error) {
    return "", .Not_Configured
}

telegram_name :: proc(ptr: rawptr) -> string {
    return "telegram"
}

telegram_is_configured :: proc(ptr: rawptr) -> bool {
    tc := (^TelegramChannel)(ptr)
    return tc.bot_token != ""
}

telegram_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

DiscordChannel :: struct {
    bot_token: string,
    channel_id: string,
}

init_discord_channel :: proc(bot_token: string, channel_id: string) -> Channel {
    dc := new(DiscordChannel)
    dc.bot_token = bot_token
    dc.channel_id = channel_id
    return Channel{ptr = dc, vtable = &discord_vtable}
}

discord_vtable := Channel_VTable{
    send = discord_send,
    receive = discord_receive,
    name = discord_name,
    is_configured = discord_is_configured,
    deinit = discord_deinit,
}

discord_send :: proc(ptr: rawptr, message: string) -> Channel_Error {
    dc := (^DiscordChannel)(ptr)
    if dc.bot_token == "" || dc.channel_id == "" {
        return .Not_Configured
    }

    url := fmt.tprintf("https://discord.com/api/v10/channels/%s/messages", dc.channel_id)
    escaped := escape_json_string(message)
    defer delete(escaped)

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"content":"`)
    strings.write_string(&sb, escaped)
    strings.write_string(&sb, `"}`)
    body := strings.clone(strings.to_string(sb))
    defer delete(body)

    headers := []string{
        fmt.tprintf("Authorization: Bot %s", dc.bot_token),
        "Content-Type: application/json",
    }
    resp, err := http_post_request(url, body, headers)
    if err != .None {
        fmt.printf("[Discord] Send failed: %v\n", err)
        return .Send_Failed
    }
    defer delete(resp.body)

    if resp.status_code < 200 || resp.status_code >= 300 {
        fmt.printf("[Discord] Send failed: status=%d\n", resp.status_code)
        return .Send_Failed
    }

    fmt.printf("[Discord] Message sent (status=%d)\n", resp.status_code)
    return .None
}

discord_receive :: proc(ptr: rawptr) -> (string, Channel_Error) {
    return "", .Not_Configured
}

discord_name :: proc(ptr: rawptr) -> string {
    return "discord"
}

discord_is_configured :: proc(ptr: rawptr) -> bool {
    dc := (^DiscordChannel)(ptr)
    return dc.bot_token != ""
}

discord_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

create_channels_from_config :: proc(config: ^Config) -> []Channel {
    channels := make([dynamic]Channel)
    
    if config.channels.slack_webhook_url != "" {
        append(&channels, init_slack_channel(config.channels.slack_webhook_url, "", ""))
    }
    
    if config.channels.telegram_api_key != "" {
        append(&channels, init_telegram_channel(config.channels.telegram_api_key))
    }
    
    if config.channels.discord_token != "" {
        append(&channels, init_discord_channel(config.channels.discord_token, ""))
    }

    if config.channels.irc_server != "" && config.channels.irc_nick != "" && config.channels.irc_channel != "" {
        append(&channels, init_irc_channel(config.channels.irc_server, config.channels.irc_nick, config.channels.irc_channel, 6667))
    }

    if config.channels.matrix_homeserver != "" {
        append(&channels, init_matrix_channel(config.channels.matrix_homeserver, "", ""))
    }

    if config.channels.email_smtp_host != "" && config.channels.email_from != "" && config.channels.email_to != "" {
        append(&channels, init_email_channel(config.channels.email_smtp_host, 587, "", "", config.channels.email_from, config.channels.email_to))
    }

    return channels[:]
}

deinit_channels :: proc(channels: []Channel) {
    for ch in channels {
        deinit_channel(ch)
    }
    delete(channels)
}

// ---------------------------------------------------------------------------
// IRC Channel
// ---------------------------------------------------------------------------

IRCChannel :: struct {
    server:       string,
    port:         int,
    nick:         string,
    channel_name: string,
    password:     string,
}

init_irc_channel :: proc(server: string, nick: string, channel_name: string, port: int) -> Channel {
    ic := new(IRCChannel)
    ic.server = server
    ic.nick = nick
    ic.channel_name = channel_name
    ic.port = port
    return Channel{ptr = ic, vtable = &irc_vtable}
}

irc_vtable := Channel_VTable{
    send = irc_send,
    receive = irc_receive,
    name = irc_name,
    is_configured = irc_is_configured,
    deinit = irc_deinit,
}

irc_send :: proc(ptr: rawptr, message: string) -> Channel_Error {
    ic := (^IRCChannel)(ptr)
    if ic.server == "" || ic.nick == "" || ic.channel_name == "" {
        return .Not_Configured
    }

    // Format the IRC PRIVMSG command
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, "PRIVMSG #")
    strings.write_string(&sb, ic.channel_name)
    strings.write_string(&sb, " :")
    strings.write_string(&sb, message)
    strings.write_string(&sb, "\r\n")
    irc_line := strings.to_string(sb)

    // Placeholder: log what would be sent via IRC relay
    fmt.printf("[IRC] Would send to %s:%d as %s -> %s", ic.server, ic.port, ic.nick, irc_line)
    return .None
}

irc_receive :: proc(ptr: rawptr) -> (string, Channel_Error) {
    ic := (^IRCChannel)(ptr)
    if ic.server == "" || ic.nick == "" {
        return "", .Not_Configured
    }
    return "", .Not_Configured
}

irc_name :: proc(ptr: rawptr) -> string {
    return "irc"
}

irc_is_configured :: proc(ptr: rawptr) -> bool {
    ic := (^IRCChannel)(ptr)
    return ic.server != "" && ic.nick != "" && ic.channel_name != ""
}

irc_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

// ---------------------------------------------------------------------------
// Matrix Channel
// ---------------------------------------------------------------------------

MatrixChannel :: struct {
    homeserver:   string,
    access_token: string,
    room_id:      string,
}

init_matrix_channel :: proc(homeserver: string, access_token: string, room_id: string) -> Channel {
    mc := new(MatrixChannel)
    mc.homeserver = homeserver
    mc.access_token = access_token
    mc.room_id = room_id
    return Channel{ptr = mc, vtable = &matrix_vtable}
}

matrix_vtable := Channel_VTable{
    send = matrix_send,
    receive = matrix_receive,
    name = matrix_name,
    is_configured = matrix_is_configured,
    deinit = matrix_deinit,
}

matrix_send :: proc(ptr: rawptr, message: string) -> Channel_Error {
    mc := (^MatrixChannel)(ptr)
    if mc.homeserver == "" || mc.access_token == "" || mc.room_id == "" {
        return .Not_Configured
    }

    // Use a simple incrementing txn_id placeholder
    txn_id := "txn_0"
    url := fmt.tprintf("%s/_matrix/client/r0/rooms/%s/send/m.room.message/%s", mc.homeserver, mc.room_id, txn_id)

    escaped := escape_json_string(message)
    defer delete(escaped)

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"msgtype":"m.text","body":"`)
    strings.write_string(&sb, escaped)
    strings.write_string(&sb, `"}`)
    body := strings.clone(strings.to_string(sb))
    defer delete(body)

    headers := []string{
        fmt.tprintf("Authorization: Bearer %s", mc.access_token),
        "Content-Type: application/json",
    }
    resp, err := http_request("PUT", url, body, headers)
    if err != .None {
        fmt.printf("[Matrix] Send failed: %v\n", err)
        return .Send_Failed
    }
    defer delete(resp.body)

    if resp.status_code < 200 || resp.status_code >= 300 {
        fmt.printf("[Matrix] Send failed: status=%d\n", resp.status_code)
        return .Send_Failed
    }

    fmt.printf("[Matrix] Message sent (status=%d)\n", resp.status_code)
    return .None
}

matrix_receive :: proc(ptr: rawptr) -> (string, Channel_Error) {
    mc := (^MatrixChannel)(ptr)
    if mc.homeserver == "" || mc.access_token == "" {
        return "", .Not_Configured
    }
    return "", .Not_Configured
}

matrix_name :: proc(ptr: rawptr) -> string {
    return "matrix"
}

matrix_is_configured :: proc(ptr: rawptr) -> bool {
    mc := (^MatrixChannel)(ptr)
    return mc.homeserver != "" && mc.access_token != "" && mc.room_id != ""
}

matrix_deinit :: proc(ptr: rawptr) {
    free(ptr)
}

// ---------------------------------------------------------------------------
// Email Channel
// ---------------------------------------------------------------------------

EmailChannel :: struct {
    smtp_host: string,
    smtp_port: int,
    username:  string,
    password:  string,
    from_addr: string,
    to_addr:   string,
}

init_email_channel :: proc(smtp_host: string, smtp_port: int, username: string, password: string, from_addr: string, to_addr: string) -> Channel {
    ec := new(EmailChannel)
    ec.smtp_host = smtp_host
    ec.smtp_port = smtp_port
    ec.username = username
    ec.password = password
    ec.from_addr = from_addr
    ec.to_addr = to_addr
    return Channel{ptr = ec, vtable = &email_vtable}
}

email_vtable := Channel_VTable{
    send = email_send,
    receive = email_receive,
    name = email_name,
    is_configured = email_is_configured,
    deinit = email_deinit,
}

email_send :: proc(ptr: rawptr, message: string) -> Channel_Error {
    ec := (^EmailChannel)(ptr)
    if ec.smtp_host == "" || ec.from_addr == "" || ec.to_addr == "" {
        return .Not_Configured
    }

    // Placeholder: log the email parameters (real SMTP would need raw TCP)
    fmt.printf("[Email] Would send via %s:%d\n", ec.smtp_host, ec.smtp_port)
    fmt.printf("[Email] From: %s  To: %s\n", ec.from_addr, ec.to_addr)
    fmt.printf("[Email] Body: %s\n", message)
    return .None
}

email_receive :: proc(ptr: rawptr) -> (string, Channel_Error) {
    ec := (^EmailChannel)(ptr)
    if ec.smtp_host == "" {
        return "", .Not_Configured
    }
    return "", .Not_Configured
}

email_name :: proc(ptr: rawptr) -> string {
    return "email"
}

email_is_configured :: proc(ptr: rawptr) -> bool {
    ec := (^EmailChannel)(ptr)
    return ec.smtp_host != "" && ec.from_addr != "" && ec.to_addr != ""
}

email_deinit :: proc(ptr: rawptr) {
    free(ptr)
}
