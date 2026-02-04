const std = @import("std");
const c = @cImport({
    @cInclude("iso.h");
});

pub const CloudInitError = error{
    TemplateReadFailed,
    UserDataWriteFailed,
    MetaDataWriteFailed,
    IsoCreationFailed,
};

pub fn createCloudInitISO(
    io: std.Io,
    allocator: std.mem.Allocator,
    domain_name: []const u8,
    template_path: []const u8,
    output_iso_path: []const u8,
) !void {
    // Read the template user-data file
    const template_content = try std.Io.Dir.cwd().readFileAlloc(io, template_path, allocator, .unlimited);
    defer allocator.free(template_content);

    // Create user-data with machine-id regeneration commands
    const user_data_path = try std.fmt.allocPrint(allocator, "/tmp/{s}-user-data", .{domain_name});
    defer allocator.free(user_data_path);

    const user_data_file = try std.Io.Dir.cwd().createFile(io, user_data_path, .{});
    defer user_data_file.close(io);

    // Combine template with bootcmd to regenerate machine-id
    const user_data_content = try std.fmt.allocPrint(allocator,
        \\{s}
        \\bootcmd:
        \\  - rm -f /etc/machine-id
        \\  - systemd-machine-id-setup
        \\
    , .{template_content});
    defer allocator.free(user_data_content);

    try user_data_file.writeStreamingAll(io, user_data_content);

    // Create meta-data file
    const meta_data_path = try std.fmt.allocPrint(allocator, "/tmp/{s}-meta-data", .{domain_name});
    defer allocator.free(meta_data_path);

    // Generate unique instance-id based on domain name hash
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(domain_name);
    const hash = hasher.final();

    const meta_file = try std.Io.Dir.cwd().createFile(io, meta_data_path, .{});
    defer meta_file.close(io);

    const meta_content = try std.fmt.allocPrint(allocator, "instance-id: {s}-{x}\nlocal-hostname: {s}\n", .{ domain_name, hash, domain_name });
    defer allocator.free(meta_content);
    try meta_file.writeStreamingAll(io, meta_content);

    // Delete existing ISO if it exists
    std.Io.Dir.cwd().deleteFile(io, output_iso_path) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Could not delete old ISO: {}", .{err});
        }
    };

    // Create ISO with user-data and meta-data via C function
    try createISO(allocator, output_iso_path, user_data_path, meta_data_path);

    // Clean up temporary files
    std.Io.Dir.cwd().deleteFile(io, user_data_path) catch |err| {
        std.log.warn("Could not delete user-data temp file: {}", .{err});
    };
    std.Io.Dir.cwd().deleteFile(io, meta_data_path) catch |err| {
        std.log.warn("Could not delete meta-data temp file: {}", .{err});
    };
}

fn createISO(
    allocator: std.mem.Allocator,
    output: []const u8,
    user_data: []const u8,
    meta_data: []const u8,
) !void {
    // Convert Zig strings to C strings
    var c_output = try allocator.alloc(u8, output.len + 1);
    defer allocator.free(c_output);
    @memcpy(c_output[0..output.len], output);
    c_output[output.len] = 0;

    var c_user_data = try allocator.alloc(u8, user_data.len + 1);
    defer allocator.free(c_user_data);
    @memcpy(c_user_data[0..user_data.len], user_data);
    c_user_data[user_data.len] = 0;

    var c_meta_data = try allocator.alloc(u8, meta_data.len + 1);
    defer allocator.free(c_meta_data);
    @memcpy(c_meta_data[0..meta_data.len], meta_data);
    c_meta_data[meta_data.len] = 0;

    const rc = c.zm_geniso(
        @as([*c]const u8, @ptrCast(c_output.ptr)),
        @as([*c]const u8, @ptrCast(c_user_data.ptr)),
        @as([*c]const u8, @ptrCast(c_meta_data.ptr)),
    );

    if (rc != 0) {
        std.log.err("Failed to create cloud-init ISO: exit code {d}", .{rc});
        return CloudInitError.IsoCreationFailed;
    }
}
