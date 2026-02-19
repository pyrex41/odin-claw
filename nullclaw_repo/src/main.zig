const std = @import("std");
const yc = @import("nullclaw");

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    std.fs.File.stderr().writeAll("panic: ") catch {};
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}

const log = std.log.scoped(.main);

const Command = enum {
    agent,
    gateway,
    daemon,
    service,
    status,
    onboard,
    doctor,
    cron,
    channel,
    skills,
    hardware,
    migrate,
    models,
    help,
};

fn parseCommand(arg: []const u8) ?Command {
    const command_map = std.StaticStringMap(Command).initComptime(.{
        .{ "agent", .agent },
        .{ "gateway", .gateway },
        .{ "daemon", .daemon },
        .{ "service", .service },
        .{ "status", .status },
        .{ "onboard", .onboard },
        .{ "doctor", .doctor },
        .{ "cron", .cron },
        .{ "channel", .channel },
        .{ "skills", .skills },
        .{ "hardware", .hardware },
        .{ "migrate", .migrate },
        .{ "models", .models },
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
    });
    return command_map.get(arg);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = parseCommand(args[1]) orelse {
        std.debug.print("Unknown command: {s}\n\n", .{args[1]});
        printUsage();
        std.process.exit(1);
    };

    const sub_args = args[2..];

    switch (cmd) {
        .status => try yc.status.run(allocator),
        .agent => try yc.agent.run(allocator, sub_args),
        .onboard => try runOnboard(allocator, sub_args),
        .doctor => try yc.doctor.run(allocator),
        .help => printUsage(),
        .gateway => try runGateway(allocator, sub_args),
        .daemon => try runDaemon(allocator, sub_args),
        .service => try runService(allocator, sub_args),
        .cron => try runCron(allocator, sub_args),
        .channel => try runChannel(allocator, sub_args),
        .skills => try runSkills(allocator, sub_args),
        .hardware => try runHardware(allocator, sub_args),
        .migrate => try runMigrate(allocator, sub_args),
        .models => try runModels(allocator, sub_args),
    }
}

// ── Gateway ──────────────────────────────────────────────────────

fn runGateway(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var port: u16 = 3000;
    var host: []const u8 = "127.0.0.1";

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if ((std.mem.eql(u8, sub_args[i], "--port") or std.mem.eql(u8, sub_args[i], "-p")) and i + 1 < sub_args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, sub_args[i], 10) catch {
                std.debug.print("Invalid port: {s}\n", .{sub_args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, sub_args[i], "--host") and i + 1 < sub_args.len) {
            i += 1;
            host = sub_args[i];
        }
    }

    _ = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullclaw onboard` first\n", .{});
        std.process.exit(1);
    };

    try yc.gateway.run(allocator, host, port);
}

// ── Daemon ───────────────────────────────────────────────────────

fn runDaemon(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var port: u16 = 3000;
    var host: []const u8 = "127.0.0.1";

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if ((std.mem.eql(u8, sub_args[i], "--port") or std.mem.eql(u8, sub_args[i], "-p")) and i + 1 < sub_args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, sub_args[i], 10) catch {
                std.debug.print("Invalid port: {s}\n", .{sub_args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, sub_args[i], "--host") and i + 1 < sub_args.len) {
            i += 1;
            host = sub_args[i];
        }
    }

    const cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullclaw onboard` first\n", .{});
        std.process.exit(1);
    };

    try yc.daemon.run(allocator, &cfg, host, port);
}

// ── Service ──────────────────────────────────────────────────────

fn runService(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print("Usage: nullclaw service <install|start|stop|status|uninstall>\n", .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];
    const service_cmd: yc.service.ServiceCommand = blk: {
        const map = .{
            .{ "install", yc.service.ServiceCommand.install },
            .{ "start", yc.service.ServiceCommand.start },
            .{ "stop", yc.service.ServiceCommand.stop },
            .{ "status", yc.service.ServiceCommand.status },
            .{ "uninstall", yc.service.ServiceCommand.uninstall },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, subcmd, entry[0])) break :blk entry[1];
        }
        std.debug.print("Unknown service command: {s}\n", .{subcmd});
        std.debug.print("Usage: nullclaw service <install|start|stop|status|uninstall>\n", .{});
        std.process.exit(1);
    };

    const cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullclaw onboard` first\n", .{});
        std.process.exit(1);
    };

    try yc.service.handleCommand(allocator, service_cmd, cfg.config_path);
}

// ── Cron ─────────────────────────────────────────────────────────

fn runCron(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullclaw cron <command> [args]
            \\
            \\Commands:
            \\  list                          List all scheduled tasks
            \\  add <expression> <command>    Add a recurring cron job
            \\  once <delay> <command>        Add a one-shot delayed task
            \\  remove <id>                   Remove a scheduled task
            \\  pause <id>                    Pause a scheduled task
            \\  resume <id>                   Resume a paused task
            \\  run <id>                      Run a scheduled task immediately
            \\  update <id> [options]         Update a cron job
            \\  runs <id>                     List recent run history for a job
            \\
        , .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        try yc.cron.cliListJobs(allocator);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (sub_args.len < 3) {
            std.debug.print("Usage: nullclaw cron add <expression> <command>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliAddJob(allocator, sub_args[1], sub_args[2]);
    } else if (std.mem.eql(u8, subcmd, "once")) {
        if (sub_args.len < 3) {
            std.debug.print("Usage: nullclaw cron once <delay> <command>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliAddOnce(allocator, sub_args[1], sub_args[2]);
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw cron remove <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliRemoveJob(allocator, sub_args[1]);
    } else if (std.mem.eql(u8, subcmd, "pause")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw cron pause <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliPauseJob(allocator, sub_args[1]);
    } else if (std.mem.eql(u8, subcmd, "resume")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw cron resume <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliResumeJob(allocator, sub_args[1]);
    } else if (std.mem.eql(u8, subcmd, "run")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw cron run <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliRunJob(allocator, sub_args[1]);
    } else if (std.mem.eql(u8, subcmd, "update")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw cron update <id> [--expression <expr>] [--command <cmd>] [--enable] [--disable]\n", .{});
            std.process.exit(1);
        }
        const id = sub_args[1];
        var expression: ?[]const u8 = null;
        var command: ?[]const u8 = null;
        var enabled: ?bool = null;
        var i: usize = 2;
        while (i < sub_args.len) : (i += 1) {
            if (std.mem.eql(u8, sub_args[i], "--expression") and i + 1 < sub_args.len) {
                i += 1;
                expression = sub_args[i];
            } else if (std.mem.eql(u8, sub_args[i], "--command") and i + 1 < sub_args.len) {
                i += 1;
                command = sub_args[i];
            } else if (std.mem.eql(u8, sub_args[i], "--enable")) {
                enabled = true;
            } else if (std.mem.eql(u8, sub_args[i], "--disable")) {
                enabled = false;
            }
        }
        try yc.cron.cliUpdateJob(allocator, id, expression, command, enabled);
    } else if (std.mem.eql(u8, subcmd, "runs")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw cron runs <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliListRuns(allocator, sub_args[1]);
    } else {
        std.debug.print("Unknown cron command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Channel ──────────────────────────────────────────────────────

fn runChannel(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullclaw channel <command> [args]
            \\
            \\Commands:
            \\  list                          List configured channels
            \\  start                         Start all configured channels
            \\  doctor                        Run health checks
            \\  add <type> <config_json>      Add a channel
            \\  remove <name>                 Remove a channel
            \\
        , .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    const cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullclaw onboard` first\n", .{});
        std.process.exit(1);
    };

    if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("Configured channels:\n", .{});
        std.debug.print("  CLI:       {s}\n", .{if (cfg.channels.cli) "enabled" else "disabled"});
        std.debug.print("  Telegram:  {s}\n", .{if (cfg.channels.telegram != null) "configured" else "not configured"});
        std.debug.print("  Discord:   {s}\n", .{if (cfg.channels.discord != null) "configured" else "not configured"});
        std.debug.print("  Slack:     {s}\n", .{if (cfg.channels.slack != null) "configured" else "not configured"});
        std.debug.print("  Webhook:   {s}\n", .{if (cfg.channels.webhook != null) "configured" else "not configured"});
        std.debug.print("  iMessage:  {s}\n", .{if (cfg.channels.imessage != null) "configured" else "not configured"});
        std.debug.print("  Matrix:    {s}\n", .{if (cfg.channels.matrix != null) "configured" else "not configured"});
        std.debug.print("  WhatsApp:  {s}\n", .{if (cfg.channels.whatsapp != null) "configured" else "not configured"});
        std.debug.print("  IRC:       {s}\n", .{if (cfg.channels.irc != null) "configured" else "not configured"});
        std.debug.print("  Lark:      {s}\n", .{if (cfg.channels.lark != null) "configured" else "not configured"});
        std.debug.print("  DingTalk:  {s}\n", .{if (cfg.channels.dingtalk != null) "configured" else "not configured"});
    } else if (std.mem.eql(u8, subcmd, "start")) {
        try runChannelStart(allocator, sub_args[1..]);
    } else if (std.mem.eql(u8, subcmd, "doctor")) {
        std.debug.print("Channel health:\n", .{});
        std.debug.print("  CLI:      ok\n", .{});
        if (cfg.channels.telegram != null) std.debug.print("  Telegram: configured (use `channel start` to verify)\n", .{});
        if (cfg.channels.discord != null) std.debug.print("  Discord:  configured (use `channel start` to verify)\n", .{});
        if (cfg.channels.slack != null) std.debug.print("  Slack:    configured (use `channel start` to verify)\n", .{});
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw channel add <type>\n", .{});
            std.debug.print("Types: telegram, discord, slack, webhook, matrix, whatsapp, irc, lark, dingtalk\n", .{});
            std.process.exit(1);
        }
        std.debug.print("To add a '{s}' channel, edit your config file:\n  {s}\n", .{ sub_args[1], cfg.config_path });
        std.debug.print("Add a \"{s}\" object under \"channels\" with the required fields.\n", .{sub_args[1]});
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw channel remove <name>\n", .{});
            std.process.exit(1);
        }
        std.debug.print("To remove the '{s}' channel, edit your config file:\n  {s}\n", .{ sub_args[1], cfg.config_path });
        std.debug.print("Remove or set the \"{s}\" object to null under \"channels\".\n", .{sub_args[1]});
    } else {
        std.debug.print("Unknown channel command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Skills ───────────────────────────────────────────────────────

fn runSkills(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullclaw skills <command> [args]
            \\
            \\Commands:
            \\  list                          List installed skills
            \\  install <source>              Install from GitHub URL or path
            \\  remove <name>                 Remove a skill
            \\  info <name>                   Show skill details
            \\
        , .{});
        std.process.exit(1);
    }

    const cfg = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullclaw onboard` first\n", .{});
        std.process.exit(1);
    };

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        const skills_list = yc.skills.listSkills(allocator, cfg.workspace_dir) catch |err| {
            std.debug.print("Failed to list skills: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer yc.skills.freeSkills(allocator, skills_list);

        if (skills_list.len == 0) {
            std.debug.print("No skills installed.\n", .{});
        } else {
            std.debug.print("Installed skills ({d}):\n", .{skills_list.len});
            for (skills_list) |skill| {
                std.debug.print("  {s} v{s}", .{ skill.name, skill.version });
                if (skill.description.len > 0) {
                    std.debug.print(" -- {s}", .{skill.description});
                }
                std.debug.print("\n", .{});
            }
        }
    } else if (std.mem.eql(u8, subcmd, "install")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw skills install <source>\n", .{});
            std.process.exit(1);
        }
        yc.skills.installSkillFromPath(allocator, sub_args[1], cfg.workspace_dir) catch |err| {
            std.debug.print("Failed to install skill: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("Skill installed from: {s}\n", .{sub_args[1]});
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw skills remove <name>\n", .{});
            std.process.exit(1);
        }
        yc.skills.removeSkill(allocator, sub_args[1], cfg.workspace_dir) catch |err| {
            std.debug.print("Failed to remove skill '{s}': {s}\n", .{ sub_args[1], @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("Removed skill: {s}\n", .{sub_args[1]});
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw skills info <name>\n", .{});
            std.process.exit(1);
        }
        const skill_path = std.fmt.allocPrint(allocator, "{s}/skills/{s}", .{ cfg.workspace_dir, sub_args[1] }) catch {
            std.debug.print("Out of memory\n", .{});
            std.process.exit(1);
        };
        defer allocator.free(skill_path);

        const skill = yc.skills.loadSkill(allocator, skill_path) catch {
            std.debug.print("Skill '{s}' not found or invalid.\n", .{sub_args[1]});
            std.process.exit(1);
        };
        defer yc.skills.freeSkill(allocator, &skill);

        std.debug.print("Skill: {s}\n", .{skill.name});
        std.debug.print("  Version:     {s}\n", .{skill.version});
        if (skill.description.len > 0) {
            std.debug.print("  Description: {s}\n", .{skill.description});
        }
        if (skill.author.len > 0) {
            std.debug.print("  Author:      {s}\n", .{skill.author});
        }
        std.debug.print("  Enabled:     {}\n", .{skill.enabled});
        if (skill.instructions.len > 0) {
            std.debug.print("  Instructions: {d} bytes\n", .{skill.instructions.len});
        }
    } else {
        std.debug.print("Unknown skills command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Hardware ─────────────────────────────────────────────────────

fn runHardware(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullclaw hardware <command> [args]
            \\
            \\Commands:
            \\  scan                          Scan for connected hardware
            \\  flash                         Flash firmware to a device
            \\  monitor                       Monitor connected devices
            \\
        , .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "scan")) {
        std.debug.print("Scanning for hardware devices...\n", .{});
        std.debug.print("Known board registry: {d} entries\n", .{yc.hardware.knownBoards().len});

        const devices = yc.hardware.discoverHardware(allocator) catch |err| {
            std.debug.print("Discovery failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer yc.hardware.freeDiscoveredDevices(allocator, devices);

        if (devices.len == 0) {
            std.debug.print("No recognized devices found.\n", .{});
        } else {
            std.debug.print("Discovered {d} device(s):\n", .{devices.len});
            for (devices) |dev| {
                std.debug.print("  {s}", .{dev.name});
                if (dev.detail) |det| {
                    std.debug.print(" ({s})", .{det});
                }
                if (dev.device_path) |path| {
                    std.debug.print(" @ {s}", .{path});
                }
                std.debug.print("\n", .{});
            }
        }
    } else if (std.mem.eql(u8, subcmd, "flash")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw hardware flash <firmware_file> [--target <board>]\n", .{});
            std.process.exit(1);
        }
        std.debug.print("Flash not yet implemented. Firmware file: {s}\n", .{sub_args[1]});
    } else if (std.mem.eql(u8, subcmd, "monitor")) {
        std.debug.print("Monitor not yet implemented. Use `nullclaw hardware scan` to discover devices first.\n", .{});
    } else {
        std.debug.print("Unknown hardware command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Migrate ──────────────────────────────────────────────────────

fn runMigrate(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullclaw migrate <source> [options]
            \\
            \\Sources:
            \\  openclaw                      Import from OpenClaw workspace
            \\
            \\Options:
            \\  --dry-run                     Preview without writing
            \\  --source <path>               Source workspace path
            \\
        , .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, sub_args[0], "openclaw")) {
        var dry_run = false;
        var source_path: ?[]const u8 = null;

        var i: usize = 1;
        while (i < sub_args.len) : (i += 1) {
            if (std.mem.eql(u8, sub_args[i], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, sub_args[i], "--source") and i + 1 < sub_args.len) {
                i += 1;
                source_path = sub_args[i];
            }
        }

        const cfg = yc.config.Config.load(allocator) catch {
            std.debug.print("No config found -- run `nullclaw onboard` first\n", .{});
            std.process.exit(1);
        };

        const stats = yc.migration.migrateOpenclaw(allocator, &cfg, source_path, dry_run) catch |err| {
            std.debug.print("Migration failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };

        if (dry_run) {
            std.debug.print("[DRY RUN] ", .{});
        }
        std.debug.print("Migration complete: {d} imported, {d} skipped\n", .{ stats.imported, stats.skipped_unchanged });
    } else {
        std.debug.print("Unknown migration source: {s}\n", .{sub_args[0]});
        std.process.exit(1);
    }
}

// ── Models ───────────────────────────────────────────────────────

fn runModels(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 1) {
        std.debug.print(
            \\Usage: nullclaw models <command>
            \\
            \\Commands:
            \\  list                          List available models
            \\  info <model>                  Show model details
            \\  benchmark                     Run model latency benchmark
            \\  refresh                       Refresh model catalog
            \\
        , .{});
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        const cfg = yc.config.Config.load(allocator) catch null;

        std.debug.print("Current configuration:\n", .{});
        if (cfg) |c| {
            std.debug.print("  Provider: {s}\n", .{c.default_provider});
            std.debug.print("  Model:    {s}\n", .{c.default_model orelse "(not set)"});
            std.debug.print("  Temp:     {d:.1}\n\n", .{c.default_temperature});
        } else {
            std.debug.print("  (no config -- run `nullclaw onboard` first)\n\n", .{});
        }

        std.debug.print("Known providers and default models:\n", .{});
        for (yc.onboard.known_providers) |p| {
            std.debug.print("  {s:<12} {s:<36} {s}\n", .{ p.key, p.default_model, p.label });
        }
        std.debug.print("\nUse `nullclaw models info <model>` for details.\n", .{});
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (sub_args.len < 2) {
            std.debug.print("Usage: nullclaw models info <model>\n", .{});
            std.process.exit(1);
        }
        std.debug.print("Model: {s}\n", .{sub_args[1]});
        std.debug.print("  Default provider: {s}\n", .{yc.onboard.canonicalProviderName(sub_args[1])});
        std.debug.print("  Context: varies by provider\n", .{});
        std.debug.print("  Pricing: see provider dashboard\n", .{});
    } else if (std.mem.eql(u8, subcmd, "benchmark")) {
        std.debug.print("Running model latency benchmark...\n", .{});
        std.debug.print("Configure a provider first (nullclaw onboard).\n", .{});
    } else if (std.mem.eql(u8, subcmd, "refresh")) {
        try yc.onboard.runModelsRefresh(allocator);
    } else {
        std.debug.print("Unknown models command: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Onboard ──────────────────────────────────────────────────────

fn runOnboard(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var interactive = false;
    var channels_only = false;
    var api_key: ?[]const u8 = null;
    var provider: ?[]const u8 = null;
    var memory_backend: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if (std.mem.eql(u8, sub_args[i], "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, sub_args[i], "--channels-only")) {
            channels_only = true;
        } else if (std.mem.eql(u8, sub_args[i], "--api-key") and i + 1 < sub_args.len) {
            i += 1;
            api_key = sub_args[i];
        } else if (std.mem.eql(u8, sub_args[i], "--provider") and i + 1 < sub_args.len) {
            i += 1;
            provider = sub_args[i];
        } else if (std.mem.eql(u8, sub_args[i], "--memory") and i + 1 < sub_args.len) {
            i += 1;
            memory_backend = sub_args[i];
        }
    }

    if (channels_only) {
        try yc.onboard.runChannelsOnly(allocator);
    } else if (interactive) {
        try yc.onboard.runWizard(allocator);
    } else {
        try yc.onboard.runQuickSetup(allocator, api_key, provider, memory_backend);
    }
}

// ── Channel Start (Telegram bot loop) ────────────────────────────

fn runChannelStart(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Load config
    const config = yc.config.Config.load(allocator) catch {
        std.debug.print("No config found -- run `nullclaw onboard` first\n", .{});
        std.process.exit(1);
    };

    const telegram_config = config.channels.telegram orelse {
        std.debug.print("Telegram not configured. Add to config.json:\n", .{});
        std.debug.print("  \"channels\": {{ \"telegram\": {{ \"bot_token\": \"...\" }} }}\n", .{});
        std.process.exit(1);
    };

    // Determine allowed users: --user CLI args override config allowed_users
    var user_list: std.ArrayList([]const u8) = .empty;
    defer user_list.deinit(allocator);
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--user") and i + 1 < args.len) {
                i += 1;
                user_list.append(allocator, args[i]) catch |err| log.err("failed to append user: {}", .{err});
            }
        }
    }
    const allowed: []const []const u8 = if (user_list.items.len > 0)
        user_list.items
    else
        telegram_config.allowed_users;

    if (config.api_key == null) {
        std.debug.print("No API key in config. Add api_key to ~/.nullclaw/config.json\n", .{});
        std.process.exit(1);
    }

    const model = config.default_model orelse "anthropic/claude-3.5-sonnet";
    const temperature = config.default_temperature;

    std.debug.print("nullclaw telegram bot starting...\n", .{});
    std.debug.print("  Provider: {s}\n", .{config.default_provider});
    std.debug.print("  Model: {s}\n", .{model});
    std.debug.print("  Temperature: {d:.1}\n", .{temperature});
    if (allowed.len == 0) {
        std.debug.print("  Allowed users: (none — all messages will be denied)\n", .{});
    } else if (allowed.len == 1 and std.mem.eql(u8, allowed[0], "*")) {
        std.debug.print("  Allowed users: *\n", .{});
    } else {
        std.debug.print("  Allowed users:", .{});
        for (allowed) |u| {
            std.debug.print(" {s}", .{u});
        }
        std.debug.print("\n", .{});
    }

    var tg = yc.channels.telegram.TelegramChannel.init(allocator, telegram_config.bot_token, allowed);

    // Initialize MCP tools from config
    const mcp_tools: ?[]const yc.tools.Tool = if (config.mcp_servers.len > 0)
        yc.mcp.initMcpTools(allocator, config.mcp_servers) catch |err| blk: {
            std.debug.print("  MCP: init failed: {}\n", .{err});
            break :blk null;
        }
    else
        null;

    // Create tools (for system prompt and tool calling)
    const tools = yc.tools.allTools(allocator, config.workspace_dir, .{
        .http_enabled = config.http_request.enabled,
        .browser_enabled = config.browser.enabled,
        .screenshot_enabled = true,
        .mcp_tools = mcp_tools,
        .agents = config.agents,
        .fallback_api_key = config.api_key,
        .tools_config = config.tools,
    }) catch &.{};
    defer if (tools.len > 0) allocator.free(tools);

    if (mcp_tools) |mt| {
        std.debug.print("  MCP tools: {d}\n", .{mt.len});
    }

    // Create optional memory backend (don't fail if unavailable)
    var mem_opt: ?yc.memory.Memory = null;
    const db_path = std.fs.path.joinZ(allocator, &.{ config.workspace_dir, "memory.db" }) catch null;
    defer if (db_path) |p| allocator.free(p);
    if (db_path) |p| {
        if (yc.memory.createMemory(allocator, config.memory.backend, p)) |mem| {
            mem_opt = mem;
        } else |_| {}
    }

    // Create noop observer
    var noop_obs = yc.observability.NoopObserver{};
    const obs = noop_obs.observer();

    // Create provider vtable — concrete struct must stay alive for the loop.
    // Use a tagged union so the right type lives on the stack.
    const ProviderHolder = union(enum) {
        openrouter: yc.providers.openrouter.OpenRouterProvider,
        anthropic: yc.providers.anthropic.AnthropicProvider,
        openai: yc.providers.openai.OpenAiProvider,
        gemini: yc.providers.gemini.GeminiProvider,
        ollama: yc.providers.ollama.OllamaProvider,
    };

    var holder: ProviderHolder = if (std.mem.eql(u8, config.default_provider, "anthropic"))
        .{ .anthropic = yc.providers.anthropic.AnthropicProvider.init(allocator, config.api_key, null) }
    else if (std.mem.eql(u8, config.default_provider, "openai"))
        .{ .openai = yc.providers.openai.OpenAiProvider.init(allocator, config.api_key) }
    else if (std.mem.eql(u8, config.default_provider, "gemini") or
        std.mem.eql(u8, config.default_provider, "google"))
        .{ .gemini = yc.providers.gemini.GeminiProvider.init(allocator, config.api_key) }
    else if (std.mem.eql(u8, config.default_provider, "ollama"))
        .{ .ollama = yc.providers.ollama.OllamaProvider.init(allocator, null) }
    else
        // Default: OpenRouter (also handles all other provider names)
        .{ .openrouter = yc.providers.openrouter.OpenRouterProvider.init(allocator, config.api_key) };

    const provider_i: yc.providers.Provider = switch (holder) {
        .openrouter => |*p| p.provider(),
        .anthropic => |*p| p.provider(),
        .openai => |*p| p.provider(),
        .gemini => |*p| p.provider(),
        .ollama => |*p| p.provider(),
    };

    std.debug.print("  Tools: {d} loaded\n", .{tools.len});
    std.debug.print("  Memory: {s}\n", .{if (mem_opt != null) "enabled" else "disabled"});

    // Register bot commands in Telegram's "/" menu
    tg.setMyCommands();

    // Skip messages accumulated while bot was offline
    tg.dropPendingUpdates();

    std.debug.print("  Polling for messages... (Ctrl+C to stop)\n\n", .{});

    var session_mgr = yc.session.SessionManager.init(allocator, &config, provider_i, tools, mem_opt, obs);
    defer session_mgr.deinit();

    var typing = yc.channels.telegram.TypingIndicator.init(&tg);
    var evict_counter: u32 = 0;

    // Bot loop: poll → full agent loop (tool calling) → reply
    while (true) {
        const messages = tg.pollUpdates(allocator) catch |err| {
            std.debug.print("Poll error: {}\n", .{err});
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };

        for (messages) |msg| {
            std.debug.print("[{s}] {s}: {s}\n", .{ msg.channel, msg.id, msg.content });

            // Handle /start command (Telegram-specific greeting, not sent to LLM)
            const trimmed_content = std.mem.trim(u8, msg.content, " \t\r\n");
            if (std.mem.eql(u8, trimmed_content, "/start")) {
                var greeting_buf: [512]u8 = undefined;
                const name = msg.first_name orelse msg.id;
                const greeting = std.fmt.bufPrint(&greeting_buf, "Hello, {s}! I'm nullClaw.\n\nModel: {s}\nType /help for available commands.", .{ name, model }) catch "Hello! I'm nullClaw. Type /help for commands.";
                tg.sendMessageWithReply(msg.sender, greeting, msg.message_id) catch |err| log.err("failed to send /start reply: {}", .{err});
                continue;
            }

            // Determine reply-to: always in groups, configurable in private chats
            const use_reply_to = msg.is_group or telegram_config.reply_in_private;
            const reply_to_id: ?i64 = if (use_reply_to) msg.message_id else null;

            // Session key: "telegram:{chat_id}"
            var key_buf: [128]u8 = undefined;
            const session_key = std.fmt.bufPrint(&key_buf, "telegram:{s}", .{msg.sender}) catch msg.sender;

            // Start periodic typing indicator while LLM is thinking
            typing.start(msg.sender);

            const reply = session_mgr.processMessage(session_key, msg.content) catch |err| {
                typing.stop();
                std.debug.print("  Agent error: {}\n", .{err});
                tg.sendMessageWithReply(msg.sender, "Sorry, I encountered an error.", reply_to_id) catch |send_err| log.err("failed to send error reply: {}", .{send_err});
                continue;
            };
            defer allocator.free(reply);

            typing.stop();

            std.debug.print("  -> {s}\n", .{reply});

            // Reply on telegram; handles [IMAGE:path] markers + split
            tg.sendMessageWithReply(msg.sender, reply, reply_to_id) catch |err| {
                std.debug.print("  Send error: {}\n", .{err});
            };
        }

        if (messages.len > 0) {
            // Free message memory
            for (messages) |msg| {
                allocator.free(msg.id);
                allocator.free(msg.sender);
                allocator.free(msg.content);
                if (msg.first_name) |fn_| allocator.free(fn_);
            }
            allocator.free(messages);
        }

        // Periodically evict sessions idle longer than the configured timeout
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }
    }
}

fn printUsage() void {
    const usage =
        \\nullclaw -- The smallest AI assistant. Zig-powered.
        \\
        \\USAGE:
        \\  nullclaw <command> [options]
        \\
        \\COMMANDS:
        \\  onboard     Initialize workspace and configuration
        \\  agent       Start the AI agent loop
        \\  gateway     Start the gateway server (HTTP/WebSocket)
        \\  daemon      Start long-running runtime (gateway + channels + heartbeat)
        \\  service     Manage OS service lifecycle (install/start/stop/status/uninstall)
        \\  status      Show system status
        \\  doctor      Run diagnostics
        \\  cron        Manage scheduled tasks
        \\  channel     Manage channels (Telegram, Discord, Slack, ...)
        \\  skills      Manage skills
        \\  hardware    Discover and manage hardware
        \\  migrate     Migrate data from other agent runtimes
        \\  models      Manage provider model catalogs
        \\  help        Show this help
        \\
        \\OPTIONS:
        \\  onboard [--interactive] [--api-key KEY] [--provider PROV] [--memory MEM]
        \\  agent [-m MESSAGE] [-s SESSION] [--provider PROVIDER] [--model MODEL] [--temperature TEMP]
        \\  gateway [--port PORT] [--host HOST]
        \\  daemon [--port PORT] [--host HOST]
        \\  service <install|start|stop|status|uninstall>
        \\  cron <list|add|once|remove|pause|resume> [ARGS]
        \\  channel <list|start|doctor|add|remove> [ARGS]
        \\  skills <list|install|remove> [ARGS]
        \\  hardware <discover|introspect|info> [ARGS]
        \\  migrate openclaw [--dry-run] [--source PATH]
        \\  models refresh
        \\
    ;
    std.debug.print("{s}", .{usage});
}

test "parse known commands" {
    try std.testing.expectEqual(.agent, parseCommand("agent").?);
    try std.testing.expectEqual(.status, parseCommand("status").?);
    try std.testing.expectEqual(.service, parseCommand("service").?);
    try std.testing.expectEqual(.migrate, parseCommand("migrate").?);
    try std.testing.expectEqual(.models, parseCommand("models").?);
    try std.testing.expect(parseCommand("unknown") == null);
}
