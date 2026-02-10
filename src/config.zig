const std = @import("std");

pub const Config = struct {
    base_image_path: []const u8 = "/usr/share/zm/images",
    vm_storage_path: []const u8 = "/var/lib/libvirt/images",
    cloud_init_template_path: []const u8 = "/usr/share/zm/images/cloud-init",
    default_memory: u64 = 1024 * 1024, // 1GiB in KiB
    default_vcpus: u32 = 2,
    default_machine: []const u8 = "pc-q35-10.0",
    max_retries: u32 = 30,
    username: []const u8 = "zm",
    ssh_key: []const u8 = "",
    identity_file: []const u8 = "~/.ssh/id_ed25519",
    _file_buffer: ?[]u8 = null,
    _allocator: ?std.mem.Allocator = null,

    pub fn init() Config {
        return Config{};
    }

    pub fn deinit(self: *Config) void {
        if (self._allocator) |alloc| {
            if (self._file_buffer) |buf| {
                alloc.free(buf);
            }
        }
    }

    pub fn loadFromFile(_: @This(), io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Config {
        var cfg = Config{};
        cfg._allocator = allocator;
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const buf = try allocator.alloc(u8, 1024 * 1024);
        errdefer allocator.free(buf);
        const bytes_read = try file.readPositionalAll(io, buf, 0);
        cfg._file_buffer = buf;

        // Parse YAML-style key: value config
        var lines = std.mem.splitScalar(u8, buf[0..bytes_read], '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or std.mem.startsWith(u8, trimmed, "---")) continue;

            // Split on first ": " to handle values containing colons/spaces
            const sep_idx = std.mem.indexOf(u8, trimmed, ": ") orelse continue;
            const key = std.mem.trim(u8, trimmed[0..sep_idx], " \t");
            const value = std.mem.trim(u8, trimmed[sep_idx + 2 ..], " \t");

            if (std.mem.eql(u8, key, "base_image_path")) {
                cfg.base_image_path = value;
            } else if (std.mem.eql(u8, key, "vm_storage_path")) {
                cfg.vm_storage_path = value;
            } else if (std.mem.eql(u8, key, "cloud_init_template_path")) {
                cfg.cloud_init_template_path = value;
            } else if (std.mem.eql(u8, key, "default_memory")) {
                cfg.default_memory = try std.fmt.parseInt(u64, value, 10);
            } else if (std.mem.eql(u8, key, "default_vcpus")) {
                cfg.default_vcpus = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, key, "default_machine")) {
                cfg.default_machine = value;
            } else if (std.mem.eql(u8, key, "max_retries")) {
                cfg.max_retries = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, key, "username")) {
                cfg.username = value;
            } else if (std.mem.eql(u8, key, "ssh_key")) {
                cfg.ssh_key = value;
            } else if (std.mem.eql(u8, key, "identity_file")) {
                cfg.identity_file = value;
            }
        }

        return cfg;
    }

    pub fn getDefaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const paths = &[_][]const u8{
            "/etc/zm/config.yaml",
            try std.fs.path.join(allocator, &.{ std.os.getenv("HOME") orelse "", ".config", "zm", "config.yaml" }),
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
