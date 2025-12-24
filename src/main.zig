const std = @import("std");
const config = @import("config.zig");
const vm = @import("vm.zig");
const libvirt = @import("libvirt.zig");

const version = "0.2.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(args[0]);
        std.process.exit(1);
    }

    // Handle help and version flags
    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try printHelp();
        return;
    }
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        try printVersion();
        return;
    }

    // Load configuration
    var cfg = config.Config.init();
    _ = cfg.loadFromFile(allocator, "/etc/zm/config") catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Could not load config: {}", .{err});
        }
    };

    // Open libvirt connection
    const conn = try libvirt.Connection.open("qemu:///system");
    defer conn.close();

    // Ensure default network is active
    try conn.ensureDefaultNetwork();

    // Handle subcommands
    const command = args[1];

    if (std.mem.eql(u8, command, "create")) {
        try cmdCreate(allocator, args[2..], &conn, &cfg);
    } else if (std.mem.eql(u8, command, "list")) {
        try vm.listVMs(allocator, &conn);
    } else if (std.mem.eql(u8, command, "info")) {
        try cmdInfo(allocator, args[2..], &conn);
    } else if (std.mem.eql(u8, command, "start")) {
        try cmdStart(allocator, args[2..], &conn);
    } else if (std.mem.eql(u8, command, "stop")) {
        try cmdStop(allocator, args[2..], &conn);
    } else if (std.mem.eql(u8, command, "delete")) {
        try cmdDelete(allocator, args[2..], &conn, &cfg);
    } else if (std.mem.eql(u8, command, "ip")) {
        try cmdIP(allocator, args[2..], &conn, &cfg);
    } else {
        // Legacy mode: treat as create command
        if (args.len >= 2) {
            try cmdCreate(allocator, args[1..], &conn, &cfg);
        } else {
            try printUsage(args[0]);
            std.process.exit(1);
        }
    }
}

fn printUsage(prog_name: []const u8) !void {
    std.debug.print("Usage: {s} <command> [options]\n", .{prog_name});
    std.debug.print("   or: {s} <domain-name>  (legacy mode)\n\n", .{prog_name});
    std.debug.print("Run '{s} --help' for more information.\n", .{prog_name});
}

fn printHelp() !void {
    std.debug.print(
        \\
        \\zm - A lightweight KVM/QEMU virtual machine creation tool
        \\
        \\Usage:
        \\  zm <command> [options]
        \\  zm <domain-name>                    (legacy mode: create VM)
        \\
        \\Commands:
        \\  create <name> [options]            Create a new VM
        \\  list                               List all running VMs
        \\  info <name>                        Show VM information
        \\  start <name>                       Start a VM
        \\  stop <name>                        Stop a VM
        \\  delete <name>                      Delete a VM
        \\  ip <name>                          Get VM IP address
        \\
        \\Options for 'create':
        \\  --memory <size>                    Set memory (default: 1GiB)
        \\  --vcpus <num>                      Set number of vCPUs (default: 2)
        \\  --machine <type>                   Set machine type (default: pc-q35-10.0)
        \\  --image <path>                     Use custom base image
        \\  --no-start                         Create but don't start VM
        \\  --no-wait-ip                       Don't wait for IP address
        \\
        \\Options for 'stop':
        \\  --force                             Force stop (poweroff)
        \\
        \\Options for 'delete':
        \\  --force                             Force delete running VM
        \\
        \\Global Options:
        \\  --help, -h                         Show this help message
        \\  --version, -v                      Show version information
        \\
        \\Examples:
        \\  zm create myvm
        \\  zm create myvm --memory 2GiB --vcpus 4
        \\  zm create myvm --no-start
        \\  zm list
        \\  zm start myvm
        \\  zm ip myvm
        \\
    , .{});
}

fn printVersion() !void {
    std.debug.print("zm version {s}\n", .{version});
}

fn cmdCreate(allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection, cfg: *const config.Config) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm create <name> [options]", .{});
        std.process.exit(1);
    }

    const domain_name = args[0];
    var specs = vm.VMSpecs{};

    // Parse options
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--memory")) {
            if (i + 1 >= args.len) {
                std.log.err("Error: --memory requires a value", .{});
                std.process.exit(1);
            }
            specs.memory = parseMemory(args[i + 1]) catch |err| {
                std.log.err("Error: invalid memory value: {}", .{err});
                std.process.exit(1);
            };
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--vcpus")) {
            if (i + 1 >= args.len) {
                std.log.err("Error: --vcpus requires a value", .{});
                std.process.exit(1);
            }
            specs.vcpus = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                std.log.err("Error: invalid vcpus value", .{});
                std.process.exit(1);
            };
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--machine")) {
            if (i + 1 >= args.len) {
                std.log.err("Error: --machine requires a value", .{});
                std.process.exit(1);
            }
            specs.machine = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--image")) {
            if (i + 1 >= args.len) {
                std.log.err("Error: --image requires a value", .{});
                std.process.exit(1);
            }
            specs.image_path = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--no-start")) {
            specs.start = false;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-wait-ip")) {
            specs.wait_for_ip = false;
            i += 1;
        } else {
            std.log.err("Error: unknown option: {s}", .{args[i]});
            std.process.exit(1);
        }
    }

    try vm.createVM(allocator, conn, cfg, domain_name, specs);
}

fn parseMemory(value: []const u8) !u64 {
    const len = value.len;

    // Check for unit suffix
    if (len > 2) {
        const number = value[0 .. len - 2];
        const unit = value[len - 2 ..];

        const base = try std.fmt.parseInt(u64, number, 10);

        if (std.mem.eql(u8, unit, "GiB")) {
            return base * 1024 * 1024; // Convert GiB to KiB
        } else if (std.mem.eql(u8, unit, "MiB")) {
            return base * 1024; // Convert MiB to KiB
        }
    }

    // Try parsing as raw KiB
    return std.fmt.parseInt(u64, value, 10);
}

fn cmdInfo(allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm info <name>", .{});
        std.process.exit(1);
    }

    try vm.showVMInfo(allocator, conn, args[0]);
}

fn cmdStart(allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm start <name>", .{});
        std.process.exit(1);
    }

    try vm.startVM(allocator, conn, args[0]);
}

fn cmdStop(allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm stop <name> [--force]", .{});
        std.process.exit(1);
    }

    var force = false;
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--force")) {
            force = true;
            i += 1;
        } else {
            std.log.err("Error: unknown option: {s}", .{args[i]});
            std.process.exit(1);
        }
    }

    try vm.stopVM(allocator, conn, args[0], force);
}

fn cmdDelete(allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection, cfg: *const config.Config) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm delete <name> [--force]", .{});
        std.process.exit(1);
    }

    var force = false;
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--force")) {
            force = true;
            i += 1;
        } else {
            std.log.err("Error: unknown option: {s}", .{args[i]});
            std.process.exit(1);
        }
    }

    try vm.deleteVM(allocator, conn, cfg, args[0], force);
}

fn cmdIP(allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection, cfg: *const config.Config) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm ip <name>", .{});
        std.process.exit(1);
    }

    try vm.getVMIP(allocator, conn, cfg, args[0]);
}
