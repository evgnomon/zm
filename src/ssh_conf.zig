const std = @import("std");

const ssh_config_d = "/etc/ssh/ssh_config.d";

pub const SshConfig = struct {
    host: []const u8,
    hostname: []const u8,
    user: []const u8 = "root",
    port: u16 = 22,
    identity_file: []const u8 = "~/.ssh/id_ed25519",
};

pub fn createSshHostConfig(io: std.Io, allocator: std.mem.Allocator, conf: SshConfig) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}.conf", .{conf.host});
    defer allocator.free(filename);

    const host_config_path = try std.fs.path.join(allocator, &.{ ssh_config_d, filename });
    defer allocator.free(host_config_path);

    // Format the SSH config entry
    const config_entry = try std.fmt.allocPrint(allocator,
        \\Host {s}
        \\    HostName {s}
        \\    User {s}
        \\    Port {d}
        \\    IdentityFile {s}
        \\
    , .{ conf.host, conf.hostname, conf.user, conf.port, conf.identity_file });
    defer allocator.free(config_entry);

    // Write host config to its own file
    const file = try std.Io.Dir.cwd().createFile(io, host_config_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, config_entry);
}

pub fn removeSshHostConfig(io: std.Io, allocator: std.mem.Allocator, host: []const u8) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}.conf", .{host});
    defer allocator.free(filename);

    const host_config_path = try std.fs.path.join(allocator, &.{ ssh_config_d, filename });
    defer allocator.free(host_config_path);

    std.Io.Dir.cwd().deleteFile(io, host_config_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}
