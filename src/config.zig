const std = @import("std");

pub const Config = struct {
    base_image_path: []const u8 = "/usr/share/zm/images",
    vm_storage_path: []const u8 = "/var/lib/libvirt/images",
    cloud_init_template_path: []const u8 = "/usr/share/zm/images/cloud-init",
    default_memory: u64 = 1024 * 1024, // 1GiB in KiB
    default_vcpus: u32 = 2,
    default_machine: []const u8 = "pc-q35-10.0",
    max_retries: u32 = 30,

    pub fn init() Config {
        return Config{};
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // No heap allocations in current Config
    }

    pub fn loadFromFile(_: @This(), allocator: std.mem.Allocator, path: []const u8) !Config {
        var config = Config{};
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var buf: [1024 * 1024]u8 = undefined;
        _ = try file.read(buf[0..]);

        // Simple key-value parsing (can be upgraded to YAML later)
        var lines = std.mem.splitScalar(u8, &buf, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;

            var parts = std.mem.splitScalar(u8, line, '=');
            const key = parts.next() orelse continue;
            const value = parts.next() orelse continue;

            if (std.mem.eql(u8, key, "base_image_path")) {
                const copy = try allocator.dupe(u8, value);
                config.base_image_path = copy;
            } else if (std.mem.eql(u8, key, "vm_storage_path")) {
                const copy = try allocator.dupe(u8, value);
                config.vm_storage_path = copy;
            } else if (std.mem.eql(u8, key, "cloud_init_template_path")) {
                const copy = try allocator.dupe(u8, value);
                config.cloud_init_template_path = copy;
            } else if (std.mem.eql(u8, key, "default_memory")) {
                config.default_memory = try std.fmt.parseInt(u64, value, 10);
            } else if (std.mem.eql(u8, key, "default_vcpus")) {
                config.default_vcpus = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, key, "default_machine")) {
                const copy = try allocator.dupe(u8, value);
                config.default_machine = copy;
            } else if (std.mem.eql(u8, key, "max_retries")) {
                config.max_retries = try std.fmt.parseInt(u32, value, 10);
            }
        }

        return config;
    }

    pub fn getDefaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        // Try /etc/zm/config, then ~/.config/zm/config
        const paths = &[_][]const u8{
            "/etc/zm/config",
            try std.fs.path.join(allocator, &.{ std.os.getenv("HOME") orelse "", ".config", "zm", "config" }),
        };

        for (paths) |path| {
            if (std.fs.cwd().openFile(path, .{})) |file| {
                file.close();
                return path;
            } else |_| {}
        }

        return error.ConfigNotFound;
    }
};
