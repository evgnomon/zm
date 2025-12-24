const std = @import("std");
const mem = std.mem;
const c = @cImport({
    @cInclude("libvirt/libvirt.h");
});
const libvirt = @import("libvirt.zig");

pub const NetworkError = error{
    NoInterfacesFound,
    IpNotFound,
};

pub fn getIPAddress(
    domain: *const libvirt.Domain,
    allocator: std.mem.Allocator,
    mac_addr: []const u8,
    max_retries: u32,
) ![]const u8 {
    var retry_count: u32 = 0;

    std.log.info("Attempting to get IP for {s} (MAC: {s})...", .{ domain.getName(), mac_addr });

    while (retry_count < max_retries) : (retry_count += 1) {
        const ips = domain.getIPAddresses(allocator, mac_addr) catch |err| {
            if (err == error.NoInterfacesFound) {
                // No interfaces found yet, wait and retry
                var ts: std.posix.timespec = .{ .sec = 1, .nsec = 0 };
                _ = std.posix.system.nanosleep(&ts, &ts);
                continue;
            }
            return err;
        };
        defer {
            for (ips) |ip| allocator.free(ip);
            allocator.free(ips);
        }

        if (ips.len > 0) {
            // Return the first IPv4 address found
            for (ips) |ip| {
                if (std.mem.indexOf(u8, ip, ":") == null) {
                    // IPv4 address
                    const ip_copy = try allocator.dupe(u8, ip);
                    return ip_copy;
                }
            }

            // If no IPv4, return first IPv6
            const ip_copy = try allocator.dupe(u8, ips[0]);
            return ip_copy;
        }

        // No IP found, wait and retry
        var ts: std.posix.timespec = .{ .sec = 1, .nsec = 0 };
        _ = std.posix.system.nanosleep(&ts, &ts);
    }

    return NetworkError.IpNotFound;
}

pub fn generateMACAddress(domain_name: []const u8) [17]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(domain_name);
    const hash = hasher.final();

    // Use hash to generate MAC in the QEMU/KVM reserved range (52:54:00:xx:xx:xx)
    var mac: [17]u8 = undefined;
    _ = std.fmt.bufPrint(&mac, "52:54:00:{x:0>2}:{x:0>2}:{x:0>2}", .{
        @as(u8, @truncate((hash >> 16) & 0xFF)),
        @as(u8, @truncate((hash >> 8) & 0xFF)),
        @as(u8, @truncate(hash & 0xFF)),
    }) catch unreachable;
    return mac;
}

pub fn printAllDomainIPs(conn: *const libvirt.Connection, _: std.mem.Allocator) !void {
    const max_ids: i32 = 128;
    var ids: [128]i32 = undefined;
    const n = c.virConnectListDomains(conn.conn, &ids, max_ids);

    if (n <= 0) {
        std.log.info("No running domains found", .{});
        return;
    }

    std.log.info("Running domains:", .{});

    for (ids[0..@intCast(n)]) |id| {
        if (c.virDomainLookupByID(conn.conn, id)) |d| {
            defer _ = c.virDomainFree(d);
            const name = c.virDomainGetName(d);

            // Try to get IP addresses
            var ifaces: ?*c.virDomainInterfacePtr = null;
            var nifaces: i32 = c.virDomainInterfaceAddresses(d, &ifaces, c.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT, 0);

            if (nifaces <= 0) {
                nifaces = c.virDomainInterfaceAddresses(d, &ifaces, c.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, 0);
            }

            if (nifaces > 0 and ifaces != null) {
                const iface_slice: [*]c.virDomainInterfacePtr = @ptrCast(ifaces.?);
                const count: usize = @intCast(nifaces);

                for (0..count) |idx| {
                    const iface = iface_slice[idx].*;

                    const iface_hwaddr = if (iface.hwaddr != null) mem.span(iface.hwaddr) else "";

                    for (0..@intCast(iface.naddrs)) |j| {
                        const addr = iface.addrs[j];
                        if (addr.type == c.VIR_IP_ADDR_TYPE_IPV4 or addr.type == c.VIR_IP_ADDR_TYPE_IPV6) {
                            std.log.info("  {s}: {s} (MAC: {s})", .{ iface.name, addr.addr, iface_hwaddr });
                        }
                    }
                }

                c.virDomainInterfaceFree(ifaces);
            } else {
                std.log.info("  {s}: IP not available yet", .{name});
            }
        }
    }
}
