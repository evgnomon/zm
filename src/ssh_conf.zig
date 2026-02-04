const std = @import("std");

pub const SshConfig = struct {
    host: []const u8,
    hostname: []const u8,
    user: []const u8,
    port: u16,
    identity_file: []const u8,
};

pub const SshConfigError = error{
    HomeNotFound,
};

pub fn createSshHostConfig(io: std.Io, allocator: std.mem.Allocator, conf: SshConfig) !void {
    const home = std.posix.getenv("HOME") orelse return SshConfigError.HomeNotFound;

    const config_d_path = try std.fs.path.join(allocator, &.{ home, ".ssh", "config.d" });
    defer allocator.free(config_d_path);

    const host_config_path = try std.fs.path.join(allocator, &.{ config_d_path, conf.host });
    defer allocator.free(host_config_path);

    // Ensure .ssh/config.d directory exists
    std.Io.Dir.cwd().makePath(io, config_d_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

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
    const home = std.posix.getenv("HOME") orelse return SshConfigError.HomeNotFound;

    const host_config_path = try std.fs.path.join(allocator, &.{ home, ".ssh", "config.d", host });
    defer allocator.free(host_config_path);

    try std.Io.Dir.cwd().deleteFile(io, host_config_path);
}
