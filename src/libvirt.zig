const std = @import("std");
const mem = std.mem;
const c = @cImport({
    @cInclude("libvirt/libvirt.h");
    @cInclude("libvirt/virterror.h");
    @cInclude("stdlib.h");
});

pub const LibvirtError = error{
    ConnectFailed,
    NetworkLookupFailed,
    DomainDefineFailed,
    DomainStartFailed,
    DomainLookupFailed,
    DomainDestroyFailed,
    DomainUndefineFailed,
    SnapshotCreateFailed,
    SnapshotDeleteFailed,
    SnapshotRevertFailed,
    SnapshotLookupFailed,
    SnapshotListFailed,
};

fn xmlEscape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

// Custom error handler that suppresses errors
fn ignoreErrorHandler(_: ?*anyopaque, _: c.virErrorPtr) callconv(.c) void {
    // Do nothing
}

pub const Connection = struct {
    conn: *c.virConnect,

    pub fn open(uri: ?[*:0]const u8) !Connection {
        c.virSetErrorFunc(null, ignoreErrorHandler);

        const conn = c.virConnectOpen(uri) orelse {
            std.log.err("Failed to open connection to {s}", .{uri orelse "default"});
            return LibvirtError.ConnectFailed;
        };

        return Connection{ .conn = conn };
    }

    pub fn close(self: Connection) void {
        _ = c.virConnectClose(self.conn);
    }

    pub fn ensureDefaultNetwork(self: *const Connection) !void {
        if (c.virNetworkLookupByName(self.conn, "default")) |net| {
            defer _ = c.virNetworkFree(net);

            if (c.virNetworkIsActive(net) == 0) {
                _ = c.virNetworkCreate(net);
            }
            if (c.virNetworkGetAutostart(net, null) == 0) {
                _ = c.virNetworkSetAutostart(net, 1);
            }
            std.log.info("Network 'default' is active and set to autostart", .{});
        }
    }

    pub fn listDomains(self: *const Connection, allocator: std.mem.Allocator) ![][]const u8 {
        const max_ids: i32 = 128;
        var ids: [128]i32 = undefined;
        const n = c.virConnectListDomains(self.conn, &ids, max_ids);

        if (n < 0) return error.ListFailed;

        var domains: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (domains.items) |name| allocator.free(name);
            domains.deinit(allocator);
        }

        for (ids[0..@intCast(n)]) |id| {
            if (c.virDomainLookupByID(self.conn, id)) |d| {
                defer _ = c.virDomainFree(d);
                const name = c.virDomainGetName(d);
                const name_copy = try allocator.dupe(u8, mem.span(name));
                try domains.append(allocator, name_copy);
            }
        }

        return domains.toOwnedSlice(allocator);
    }

    pub fn lookupDomain(self: *const Connection, allocator: std.mem.Allocator, name: []const u8) !Domain {
        const c_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{name});
        defer std.heap.page_allocator.free(c_name);

        const c_name_c = try allocator.dupeZ(u8, c_name);
        defer allocator.free(c_name_c);

        const dom = c.virDomainLookupByName(self.conn, c_name_c) orelse {
            return LibvirtError.DomainLookupFailed;
        };

        return Domain{ .dom = dom };
    }
};

pub const Domain = struct {
    dom: *c.virDomain,

    pub fn free(self: Domain) void {
        _ = c.virDomainFree(self.dom);
    }

    pub fn defineXML(conn: *const Connection, allocator: std.mem.Allocator, xml: []const u8) !Domain {
        const c_xml = try allocator.dupeZ(u8, xml);
        defer allocator.free(c_xml);

        const dom = c.virDomainDefineXML(conn.conn, c_xml) orelse {
            std.log.err("Failed to define domain XML", .{});
            return LibvirtError.DomainDefineFailed;
        };

        return Domain{ .dom = dom };
    }

    pub fn create(self: *const Domain) !void {
        if (c.virDomainCreate(self.dom) < 0) {
            std.log.err("Failed to start domain", .{});
            return LibvirtError.DomainStartFailed;
        }
    }

    pub fn destroy(self: *const Domain) !void {
        if (c.virDomainDestroy(self.dom) < 0) {
            return LibvirtError.DomainDestroyFailed;
        }
    }

    pub fn undefine(self: *const Domain) !void {
        if (c.virDomainUndefine(self.dom) < 0) {
            return LibvirtError.DomainUndefineFailed;
        }
    }

    pub fn getName(self: *const Domain) []const u8 {
        const name = c.virDomainGetName(self.dom);
        return mem.span(name);
    }

    pub fn getIPAddresses(self: *const Domain, allocator: std.mem.Allocator, mac_addr: []const u8) ![][]const u8 {
        var ifaces: ?*c.virDomainInterfacePtr = null;
        var nifaces: i32 = 0;

        // Prefer agent first, then fallback to lease
        nifaces = c.virDomainInterfaceAddresses(self.dom, &ifaces, c.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT, 0);
        if (nifaces <= 0) {
            nifaces = c.virDomainInterfaceAddresses(self.dom, &ifaces, c.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, 0);
        }

        if (nifaces <= 0 or ifaces == null) {
            return error.NoInterfacesFound;
        }

        defer c.virDomainInterfaceFree(ifaces.?.*);

        const iface_slice: [*]c.virDomainInterfacePtr = @ptrCast(ifaces.?);
        const count: usize = @intCast(nifaces);

        var ips: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ips.items) |ip| allocator.free(ip);
            ips.deinit(allocator);
        }

        for (0..count) |idx| {
            const iface = iface_slice[idx].*;

            const iface_hwaddr = if (iface.hwaddr != null) mem.span(iface.hwaddr) else "";
            const mac_matches = mem.eql(u8, iface_hwaddr, mac_addr);

            for (0..@intCast(iface.naddrs)) |j| {
                const addr = iface.addrs[j];
                if (addr.type == c.VIR_IP_ADDR_TYPE_IPV4 or addr.type == c.VIR_IP_ADDR_TYPE_IPV6) {
                    if (mac_matches) {
                        const ip_copy = try allocator.dupe(u8, mem.span(addr.addr));
                        try ips.append(allocator, ip_copy);
                    }
                }
            }
        }

        const s = try ips.toOwnedSlice(allocator);
        return s;
    }

    pub fn isActive(self: *const Domain) bool {
        return c.virDomainIsActive(self.dom) == 1;
    }

    pub fn createSnapshot(self: *const Domain, allocator: std.mem.Allocator, name: []const u8) !Snapshot {
        const escaped_name = try xmlEscape(allocator, name);
        defer allocator.free(escaped_name);
        const xml = try std.fmt.allocPrint(allocator, "<domainsnapshot><name>{s}</name></domainsnapshot>", .{escaped_name});
        defer allocator.free(xml);

        const c_xml = try allocator.dupeZ(u8, xml);
        defer allocator.free(c_xml);

        const snap = c.virDomainSnapshotCreateXML(self.dom, c_xml, 0) orelse {
            return LibvirtError.SnapshotCreateFailed;
        };

        return Snapshot{ .snap = snap };
    }

    pub fn revertToSnapshot(self: *const Domain, allocator: std.mem.Allocator, name: []const u8) !void {
        const c_name = try allocator.dupeZ(u8, name);
        defer allocator.free(c_name);

        const snap = c.virDomainSnapshotLookupByName(self.dom, c_name, 0) orelse {
            return LibvirtError.SnapshotLookupFailed;
        };
        defer _ = c.virDomainSnapshotFree(snap);

        if (c.virDomainRevertToSnapshot(snap, 0) < 0) {
            return LibvirtError.SnapshotRevertFailed;
        }
    }

    pub fn deleteSnapshot(self: *const Domain, allocator: std.mem.Allocator, name: []const u8) !void {
        const c_name = try allocator.dupeZ(u8, name);
        defer allocator.free(c_name);

        const snap = c.virDomainSnapshotLookupByName(self.dom, c_name, 0) orelse {
            return LibvirtError.SnapshotLookupFailed;
        };
        defer _ = c.virDomainSnapshotFree(snap);

        if (c.virDomainSnapshotDelete(snap, 0) < 0) {
            return LibvirtError.SnapshotDeleteFailed;
        }
    }

    pub fn listSnapshots(self: *const Domain, allocator: std.mem.Allocator) ![][]const u8 {
        const num = c.virDomainSnapshotNum(self.dom, 0);
        if (num < 0) return LibvirtError.SnapshotListFailed;
        if (num == 0) return allocator.alloc([]const u8, 0);

        const max_names: usize = @intCast(num);
        const names = try allocator.alloc([*c]u8, max_names);
        defer allocator.free(names);

        const n = c.virDomainSnapshotListNames(self.dom, @ptrCast(names.ptr), @intCast(max_names), 0);
        if (n < 0) return LibvirtError.SnapshotListFailed;

        const count: usize = @intCast(n);
        const c_names = names[0..count];
        defer for (c_names) |name_ptr| {
            c.free(name_ptr);
        };

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |name| allocator.free(name);
            result.deinit(allocator);
        }

        for (c_names) |name_ptr| {
            const name_copy = try allocator.dupe(u8, mem.span(name_ptr));
            result.append(allocator, name_copy) catch |err| {
                allocator.free(name_copy);
                return err;
            };
        }

        return result.toOwnedSlice(allocator);
    }

    // pub fn getState(self: *const Domain) !c.virDomainState {
    //     var state: c_int = undefined;
    //     var reason: c_int = undefined;
    //     if (c.virDomainGetState(self.dom, &state, &reason, 0) < 0) {
    //         return error.GetStateFailed;
    //     }
    //     return @as(c.virDomainState, @enumFromInt(state));
    // }
};

pub const Snapshot = struct {
    snap: *c.virDomainSnapshot,

    pub fn free(self: Snapshot) void {
        _ = c.virDomainSnapshotFree(self.snap);
    }

    pub fn delete(self: Snapshot) !void {
        if (c.virDomainSnapshotDelete(self.snap, 0) < 0) {
            return LibvirtError.SnapshotDeleteFailed;
        }
    }

    pub fn getName(self: Snapshot) []const u8 {
        const name = c.virDomainSnapshotGetName(self.snap);
        return mem.span(name);
    }
};
