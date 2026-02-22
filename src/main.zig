const std = @import("std");
const config = @import("config.zig");
const vm = @import("vm.zig");
const libvirt = @import("libvirt.zig");

const version = "0.7.0";

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = init.minimal.args;
    const args = try argv.toSlice(allocator);
    defer allocator.free(args);

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

    const io = init.io;

    // Load configuration
    var cfg = config.Config.init();
    defer cfg.deinit();
    if (cfg.loadFromFile(io, allocator, "/etc/zm/config.yaml")) |loaded| {
        cfg = loaded;
    } else |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Could not load config: {}", .{err});
        }
    }

    // Open libvirt connection
    const conn = try libvirt.Connection.open("qemu:///system");
    defer conn.close();

    // Ensure default network is active
    try conn.ensureDefaultNetwork();

    // Handle subcommands
    const command = args[1];

    if (std.mem.eql(u8, command, "create")) {
        try cmdCreate(io, allocator, args[2..], &conn, &cfg);
    } else if (std.mem.eql(u8, command, "list")) {
        try vm.listVMs(io, allocator, &conn);
    } else if (std.mem.eql(u8, command, "info")) {
        try cmdInfo(io, allocator, args[2..], &conn);
    } else if (std.mem.eql(u8, command, "start")) {
        try cmdStart(io, allocator, args[2..], &conn);
    } else if (std.mem.eql(u8, command, "stop")) {
        try cmdStop(allocator, args[2..], &conn);
    } else if (std.mem.eql(u8, command, "delete")) {
        try cmdDelete(io, allocator, args[2..], &conn, &cfg);
    } else if (std.mem.eql(u8, command, "ip")) {
        try cmdIP(allocator, args[2..], &conn, &cfg);
    } else if (std.mem.eql(u8, command, "snapshot")) {
        try cmdSnapshot(allocator, args[2..], &conn);
    } else if (std.mem.eql(u8, command, "fork")) {
        try cmdFork(io, allocator, args[2..], &conn, &cfg);
    } else {
        // Legacy mode: treat as create command
        if (args.len >= 2) {
            try cmdCreate(io, allocator, args[1..], &conn, &cfg);
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
        \\  snapshot create <name> <snap>      Create a snapshot
        \\  snapshot list <name>               List snapshots for a VM
        \\  snapshot restore <name> <snap>     Revert VM to a snapshot
        \\  snapshot delete <name> <snap>      Delete a snapshot
        \\  fork <source> <new-name> [options] Fork a VM from an external snapshot
        \\
        \\Options for 'create' and 'fork':
        \\  --memory <size>                    Set memory (default: 1GiB)
        \\  --vcpus <num>                      Set number of vCPUs (default: 2)
        \\  --disk-size <size>                 Set disk size (default: 10G)
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
        \\  zm create myvm --memory 2GiB --vcpus 4 --disk-size 20G
        \\  zm create myvm --no-start
        \\  zm fork myvm myvm-copy
        \\  zm fork myvm myvm-copy --memory 2GiB --vcpus 4
        \\  zm list
        \\  zm start myvm
        \\  zm ip myvm
        \\
    , .{});
}

fn printVersion() !void {
    std.debug.print(
        \\zm version {s}
        \\Copyright (C) 2022-26 evgnomon.org by Hamed Ghasemzadeh. All rights reserved.
        \\License: HGL General License <https://evgnomon.org/docs/hgl>
        \\There is NO warranty expressed or implied; to the extent permitted by law.
        \\
    , .{version});
}

fn cmdCreate(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection, cfg: *const config.Config) !void {
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
        } else if (std.mem.eql(u8, args[i], "--disk-size")) {
            if (i + 1 >= args.len) {
                std.log.err("Error: --disk-size requires a value", .{});
                std.process.exit(1);
            }
            specs.disk_size = parseDiskSize(args[i + 1]) catch |err| {
                std.log.err("Error: invalid disk-size value: {}", .{err});
                std.process.exit(1);
            };
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

    try vm.createVM(io, allocator, conn, cfg, domain_name, specs);
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

fn parseDiskSize(value: []const u8) !u64 {
    const len = value.len;

    // Check for 3-char suffix (GiB, MiB)
    if (len > 3) {
        const suffix = value[len - 3 ..];
        if (std.mem.eql(u8, suffix, "GiB")) {
            const base = try std.fmt.parseInt(u64, value[0 .. len - 3], 10);
            return base * 1024 * 1024 * 1024;
        } else if (std.mem.eql(u8, suffix, "MiB")) {
            const base = try std.fmt.parseInt(u64, value[0 .. len - 3], 10);
            return base * 1024 * 1024;
        }
    }

    // Check for 1-char suffix (G, M)
    if (len > 1) {
        const last = value[len - 1];
        if (last == 'G') {
            const base = try std.fmt.parseInt(u64, value[0 .. len - 1], 10);
            return base * 1024 * 1024 * 1024;
        } else if (last == 'M') {
            const base = try std.fmt.parseInt(u64, value[0 .. len - 1], 10);
            return base * 1024 * 1024;
        }
    }

    // Raw bytes
    return std.fmt.parseInt(u64, value, 10);
}

fn cmdInfo(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm info <name>", .{});
        std.process.exit(1);
    }

    try vm.showVMInfo(io, allocator, conn, args[0]);
}

fn cmdStart(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm start <name>", .{});
        std.process.exit(1);
    }

    try vm.startVM(io, allocator, conn, args[0]);
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

fn cmdDelete(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection, cfg: *const config.Config) !void {
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

    try vm.deleteVM(io, allocator, conn, cfg, args[0], force);
}

fn cmdIP(allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection, cfg: *const config.Config) !void {
    if (args.len == 0) {
        std.log.err("Error: domain name required", .{});
        std.log.err("Usage: zm ip <name>", .{});
        std.process.exit(1);
    }

    try vm.getVMIP(allocator, conn, cfg, args[0]);
}

fn cmdFork(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection, cfg: *const config.Config) !void {
    if (args.len < 2) {
        std.log.err("Error: source and destination names required", .{});
        std.log.err("Usage: zm fork <source> <new-name> [options]", .{});
        std.process.exit(1);
    }

    const source_name = args[0];
    const dest_name = args[1];
    var specs = vm.VMSpecs{};

    var i: usize = 2;
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

    try vm.forkVM(io, allocator, conn, cfg, source_name, dest_name, specs);
}

fn cmdSnapshot(allocator: std.mem.Allocator, args: []const []const u8, conn: *const libvirt.Connection) !void {
    if (args.len == 0) {
        std.log.err("Error: snapshot subcommand required", .{});
        std.log.err("Usage: zm snapshot <create|list|restore|delete> <name> [snapshot-name]", .{});
        std.process.exit(1);
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "create")) {
        if (args.len < 3) {
            std.log.err("Error: domain name and snapshot name required", .{});
            std.log.err("Usage: zm snapshot create <name> <snapshot-name>", .{});
            std.process.exit(1);
        }
        try vm.createSnapshot(allocator, conn, args[1], args[2]);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        if (args.len < 2) {
            std.log.err("Error: domain name required", .{});
            std.log.err("Usage: zm snapshot list <name>", .{});
            std.process.exit(1);
        }
        try vm.listSnapshots(allocator, conn, args[1]);
    } else if (std.mem.eql(u8, subcmd, "restore")) {
        if (args.len < 3) {
            std.log.err("Error: domain name and snapshot name required", .{});
            std.log.err("Usage: zm snapshot restore <name> <snapshot-name>", .{});
            std.process.exit(1);
        }
        try vm.restoreSnapshot(allocator, conn, args[1], args[2]);
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        if (args.len < 3) {
            std.log.err("Error: domain name and snapshot name required", .{});
            std.log.err("Usage: zm snapshot delete <name> <snapshot-name>", .{});
            std.process.exit(1);
        }
        try vm.deleteSnapshot(allocator, conn, args[1], args[2]);
    } else {
        std.log.err("Error: unknown snapshot subcommand: {s}", .{subcmd});
        std.log.err("Usage: zm snapshot <create|list|restore|delete> <name> [snapshot-name]", .{});
        std.process.exit(1);
    }
}
