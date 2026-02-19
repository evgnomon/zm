const std = @import("std");

pub fn runInit(io: std.Io, allocator: std.mem.Allocator) !void {
    const writer = io.out;

    // Prompt for username
    try writer.writeStreamingAll("Default username [zm]: ");
    const username = try readLine(io, allocator) orelse "zm";
    defer if (username.ptr != "zm".ptr) allocator.free(username);

    // Prompt for identity file
    try writer.writeStreamingAll("Identity file [~/.ssh/id_ed25519]: ");
    const identity_file = try readLine(io, allocator) orelse "~/.ssh/id_ed25519";
    defer if (identity_file.ptr != "~/.ssh/id_ed25519".ptr) allocator.free(identity_file);

    // Try to read the public key from <identity_file>.pub
    const ssh_key = blk: {
        const pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{identity_file});
        defer allocator.free(pub_path);

        // Expand ~ to HOME
        const expanded = try expandHome(allocator, pub_path);
        defer allocator.free(expanded);

        try writer.print("Reading SSH public key from {s}...\n", .{pub_path});

        if (std.Io.Dir.cwd().readFileAlloc(io, expanded, allocator, .unlimited)) |content| {
            // Trim trailing whitespace/newlines
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (trimmed.len < content.len) {
                const key = try allocator.dupe(u8, trimmed);
                allocator.free(content);
                break :blk key;
            }
            break :blk content;
        } else |_| {
            try writer.print("Could not read {s}\n", .{pub_path});
            try writer.writeStreamingAll("SSH public key: ");
            const key = try readLine(io, allocator) orelse {
                try writer.writeStreamingAll("Error: SSH public key is required.\n");
                return error.MissingSSHKey;
            };
            break :blk key;
        }
    };
    defer allocator.free(ssh_key);

    // Create directories
    try writer.writeStreamingAll("Creating directories...\n");
    try runCommand(allocator, &.{ "mkdir", "-p", "/etc/zm" });
    try runCommand(allocator, &.{ "mkdir", "-p", "/usr/share/zm/images/cloud-init" });

    // Download zamin cloud image
    try writer.writeStreamingAll("Downloading zamin cloud image...\n");
    try runCommand(allocator, &.{ "wget", "-q", "-O", "/usr/share/zm/images/zamin-0.0.1.tar.gz", "https://archive.evgnomon.org/zamin/zamin-0.0.1.tar.gz" });

    // Extract image
    try writer.writeStreamingAll("Extracting image...\n");
    try runCommand(allocator, &.{ "tar", "-xzf", "/usr/share/zm/images/zamin-0.0.1.tar.gz", "-C", "/usr/share/zm/images" });

    // Write config file
    try writer.writeStreamingAll("Writing config to /etc/zm/config.yaml...\n");
    const config_content = try std.fmt.allocPrint(allocator,
        \\base_image_path: /usr/share/zm/images
        \\vm_storage_path: /var/lib/libvirt/images
        \\cloud_init_template_path: /usr/share/zm/images/cloud-init
        \\default_memory: 1048576
        \\default_vcpus: 2
        \\default_disk_size: 10737418240
        \\default_machine: pc-q35-10.0
        \\max_retries: 30
        \\username: {s}
        \\ssh_key: {s}
        \\identity_file: {s}
        \\
    , .{ username, ssh_key, identity_file });
    defer allocator.free(config_content);

    const config_file = try std.Io.Dir.cwd().createFile(io, "/etc/zm/config.yaml", .{});
    defer config_file.close(io);
    try config_file.writeStreamingAll(io, config_content);

    // Write cloud-init template
    try writer.writeStreamingAll("Writing cloud-init template...\n");
    const cloud_init_content = try std.fmt.allocPrint(allocator,
        \\#cloud-config
        \\users:
        \\  - name: {s}
        \\    sudo: ALL=(ALL) NOPASSWD:ALL
        \\    shell: /bin/bash
        \\    ssh_authorized_keys:
        \\      - {s}
        \\
    , .{ username, ssh_key });
    defer allocator.free(cloud_init_content);

    const cloud_init_file = try std.Io.Dir.cwd().createFile(io, "/usr/share/zm/images/cloud-init/cloud-init-user-data.yaml", .{});
    defer cloud_init_file.close(io);
    try cloud_init_file.writeStreamingAll(io, cloud_init_content);

    try writer.writeStreamingAll("zm initialized successfully.\n");
}

fn readLine(io: std.Io, allocator: std.mem.Allocator) !?[]const u8 {
    var buf: [4096]u8 = undefined;
    const n = io.in.readSome(&buf) catch |err| {
        if (err == error.EndOfStream) return null;
        return err;
    };
    if (n == 0) return null;
    const line = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (line.len == 0) return null;
    return try allocator.dupe(u8, line);
}

fn expandHome(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '~') {
        const home = std.posix.getenv("HOME") orelse "/root";
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }
    return allocator.dupe(u8, path);
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.pgid = null;
    const term = try child.spawnAndWait();
    if (term.signal) |sig| {
        std.log.err("Command killed by signal: {d}", .{sig});
        return error.CommandFailed;
    }
    if (term.code != 0) {
        std.log.err("Command failed with exit code: {d}", .{term.code});
        return error.CommandFailed;
    }
}
