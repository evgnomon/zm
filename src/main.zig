const std = @import("std");
const os = std.os;
const fs = std.fs;
const mem = std.mem;
const linux = os.linux;
const Io = std.Io;
const c = @cImport({
    @cInclude("libvirt/libvirt.h");
    @cInclude("libvirt/virterror.h");
});

// Custom error handler that suppresses errors
fn ignoreErrorHandler(_: ?*anyopaque, _: c.virErrorPtr) callconv(.c) void {
    // Do nothing
}

pub fn main() !void {
    c.virSetErrorFunc(null, ignoreErrorHandler);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.log.err("Usage: {s} <domain-name>", .{args[0]});
        std.process.exit(1);
    }

    const domain_name = args[1];

    const src_image = "/usr/share/mkvm/images/zamin";

    const dst_image = try std.fmt.allocPrint(allocator, "/var/lib/libvirt/images/{s}.qcow2", .{domain_name});
    defer allocator.free(dst_image);

    const cloud_init_yaml_template = try std.fmt.allocPrint(allocator, "{s}/cloud-init-user-data.yaml", .{"/usr/share/mkvm/images/cloud-init"});
    defer allocator.free(cloud_init_yaml_template);

    const cloud_init_yaml = try std.fmt.allocPrint(allocator, "/tmp/{s}-user-data", .{domain_name});
    defer allocator.free(cloud_init_yaml);

    const cloud_init_iso = try std.fmt.allocPrint(allocator, "/tmp/{s}-cloud-init.iso", .{domain_name});
    defer allocator.free(cloud_init_iso);

    // Create cloud-init ISO
    std.log.info("Creating cloud-init ISO at {s}", .{cloud_init_iso});

    // Read the template user-data file
    const template_content = try fs.cwd().readFileAlloc(cloud_init_yaml_template, allocator, @enumFromInt(1024 * 1024));
    defer allocator.free(template_content);

    // Create user-data with machine-id regeneration commands
    const user_data_file = try fs.cwd().createFile(cloud_init_yaml, .{});
    defer user_data_file.close();

    // Combine template with bootcmd to regenerate machine-id
    const user_data_content = try std.fmt.allocPrint(allocator,
        \\{s}
        \\bootcmd:
        \\  - rm -f /etc/machine-id
        \\  - systemd-machine-id-setup
        \\
    , .{template_content});
    defer allocator.free(user_data_content);
    try user_data_file.writeAll(user_data_content);

    // Create a minimal meta-data file path (will be populated with unique instance-id)
    const meta_data = try std.fmt.allocPrint(allocator, "/tmp/{s}-meta-data", .{domain_name});
    defer allocator.free(meta_data);

    // Generate unique instance-id and hostname based on domain name hash
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(domain_name);
    const hash = hasher.final();

    // Create meta-data file BEFORE creating the ISO
    const meta_file = try fs.cwd().createFile(meta_data, .{});
    defer meta_file.close();

    const meta_content = try std.fmt.allocPrint(allocator, "instance-id: {s}-{x}\nlocal-hostname: {s}\n", .{ domain_name, hash, domain_name });
    defer allocator.free(meta_content);
    try meta_file.writeAll(meta_content);

    // Delete existing ISO if it exists
    fs.cwd().deleteFile(cloud_init_iso) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Could not delete old ISO: {}", .{err});
        }
    };

    // Create ISO with user-data and meta-data
    const iso_cmd = try std.fmt.allocPrint(allocator, "genisoimage -output {s} -volid cidata -joliet -rock -graft-points user-data={s} meta-data={s}", .{ cloud_init_iso, cloud_init_yaml, meta_data });
    defer allocator.free(iso_cmd);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", iso_cmd },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("Failed to create cloud-init ISO: {s}", .{result.stderr});
                return error.IsoCreationFailed;
            }
        },
        else => {
            std.log.err("Failed to create cloud-init ISO: {s}", .{result.stderr});
            return error.IsoCreationFailed;
        },
    }

    // 1. Copy the source image
    std.log.info("Copying image {s} -> {s}", .{ src_image, dst_image });
    try fs.cwd().copyFile(src_image, fs.cwd(), dst_image, .{});

    // Fix ownership and permissions (qemu:qemu is usually uid 107, gid 113 or similar)
    // Adjust if your system uses different IDs (check with `id qemu`)
    //
    const stat = try fs.cwd().statFile(dst_image);
    if (stat.mode & 0o666 != 0o660) {
        const file = try fs.cwd().openFile(dst_image, .{});
        defer file.close();
        try file.chmod(0o660);
    }
    // chown to qemu:qemu – skip if not root, or adjust IDs
    // os.chown(dst_image, 107, 113) catch |err| std.log.warn("chown failed: {}", .{err});

    // 2. Open libvirt connection
    const conn = c.virConnectOpen("qemu:///system") orelse {
        std.log.err("Failed to open connection to qemu:///system", .{});
        return error.LibvirtConnect;
    };
    defer _ = c.virConnectClose(conn);

    // 3. Ensure 'default' network is active and autostart
    if (c.virNetworkLookupByName(conn, "default")) |net| {
        defer _ = c.virNetworkFree(net);

        if (c.virNetworkIsActive(net) == 0) {
            _ = c.virNetworkCreate(net);
        }
        if (c.virNetworkGetAutostart(net, null) == 0) {
            _ = c.virNetworkSetAutostart(net, 1);
        }
        std.log.info("Network 'default' is active and set to autostart", .{});
    }

    // 4. Generate a unique MAC address based on domain name (reuse hash from earlier)
    // Use hash to generate MAC in the QEMU/KVM reserved range (52:54:00:xx:xx:xx)
    const mac_addr = try std.fmt.allocPrint(allocator, "52:54:00:{x:0>2}:{x:0>2}:{x:0>2}", .{
        @as(u8, @truncate((hash >> 16) & 0xFF)),
        @as(u8, @truncate((hash >> 8) & 0xFF)),
        @as(u8, @truncate(hash & 0xFF)),
    });
    defer allocator.free(mac_addr);

    // 5. Domain XML
    const xml = try std.fmt.allocPrint(allocator,
        \\<domain type='kvm'>
        \\  <name>{s}</name>
        \\  <metadata>
        \\    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
        \\      <libosinfo:os id="http://debian.org/debian/12"/>
        \\    </libosinfo:libosinfo>
        \\  </metadata>
        \\  <memory unit='KiB'>1048576</memory>
        \\  <currentMemory unit='KiB'>1048576</currentMemory>
        \\  <vcpu placement='static'>2</vcpu>
        \\  <resource>
        \\    <partition>/machine</partition>
        \\  </resource>
        \\  <sysinfo type='smbios'>
        \\    <system>
        \\      <entry name='serial'>ds=nocloud</entry>
        \\    </system>
        \\  </sysinfo>
        \\  <os>
        \\    <type arch='x86_64' machine='pc-q35-10.0'>hvm</type>
        \\    <boot dev='hd'/>
        \\    <smbios mode='sysinfo'/>
        \\  </os>
        \\  <features>
        \\    <acpi/>
        \\    <apic/>
        \\    <vmport state='off'/>
        \\  </features>
        \\  <cpu mode='host-passthrough' check='none' migratable='on'/>
        \\  <clock offset='utc'>
        \\    <timer name='rtc' tickpolicy='catchup'/>
        \\    <timer name='pit' tickpolicy='delay'/>
        \\    <timer name='hpet' present='no'/>
        \\  </clock>
        \\  <on_poweroff>destroy</on_poweroff>
        \\  <on_reboot>destroy</on_reboot>
        \\  <on_crash>destroy</on_crash>
        \\  <pm>
        \\    <suspend-to-mem enabled='no'/>
        \\    <suspend-to-disk enabled='no'/>
        \\  </pm>
        \\  <devices>
        \\    <emulator>/usr/bin/qemu-system-x86_64</emulator>
        \\    <disk type='file' device='disk'>
        \\      <driver name='qemu' type='qcow2'/>
        \\      <source file='{s}'/>
        \\      <backingStore/>
        \\      <target dev='vda' bus='virtio'/>
        \\      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
        \\    </disk>
        \\    <disk type='file' device='cdrom'>
        \\      <driver name='qemu' type='raw'/>
        \\      <source file='{s}'/>
        \\      <backingStore/>
        \\      <target dev='sda' bus='sata'/>
        \\      <readonly/>
        \\      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
        \\    </disk>
        \\    <controller type='usb' index='0' model='qemu-xhci' ports='15'>
        \\      <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
        \\    </controller>
        \\    <controller type='pci' index='0' model='pcie-root'/>
        \\    <controller type='pci' index='1' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='1' port='0x10'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0' multifunction='on'/>
        \\    </controller>
        \\    <controller type='pci' index='2' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='2' port='0x11'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x1'/>
        \\    </controller>
        \\    <controller type='pci' index='3' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='3' port='0x12'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x2'/>
        \\    </controller>
        \\    <controller type='pci' index='4' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='4' port='0x13'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x3'/>
        \\    </controller>
        \\    <controller type='pci' index='5' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='5' port='0x14'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x4'/>
        \\    </controller>
        \\    <controller type='pci' index='6' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='6' port='0x15'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x5'/>
        \\    </controller>
        \\    <controller type='pci' index='7' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='7' port='0x16'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x6'/>
        \\    </controller>
        \\    <controller type='pci' index='8' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='8' port='0x17'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x7'/>
        \\    </controller>
        \\    <controller type='pci' index='9' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='9' port='0x18'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0' multifunction='on'/>
        \\    </controller>
        \\    <controller type='pci' index='10' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='10' port='0x19'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x1'/>
        \\    </controller>
        \\    <controller type='pci' index='11' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='11' port='0x1a'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x2'/>
        \\    </controller>
        \\    <controller type='pci' index='12' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='12' port='0x1b'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x3'/>
        \\    </controller>
        \\    <controller type='pci' index='13' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='13' port='0x1c'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x4'/>
        \\    </controller>
        \\    <controller type='pci' index='14' model='pcie-root-port'>
        \\      <model name='pcie-root-port'/>
        \\      <target chassis='14' port='0x1d'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x5'/>
        \\    </controller>
        \\    <controller type='sata' index='0'>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x1f' function='0x2'/>
        \\    </controller>
        \\    <controller type='virtio-serial' index='0'>
        \\      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
        \\    </controller>
        \\    <interface type='network'>
        \\      <mac address='{s}'/>
        \\      <source network='default'/>
        \\      <model type='virtio'/>
        \\      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
        \\    </interface>
        \\    <serial type='pty'>
        \\      <target type='isa-serial' port='0'>
        \\        <model name='isa-serial'/>
        \\      </target>
        \\    </serial>
        \\    <console type='pty'>
        \\      <target type='serial' port='0'/>
        \\    </console>
        \\    <channel type='unix'>
        \\      <target type='virtio' name='org.qemu.guest_agent.0'/>
        \\      <address type='virtio-serial' controller='0' bus='0' port='1'/>
        \\    </channel>
        \\    <channel type='spicevmc'>
        \\      <target type='virtio' name='com.redhat.spice.0'/>
        \\      <address type='virtio-serial' controller='0' bus='0' port='2'/>
        \\    </channel>
        \\    <input type='tablet' bus='usb'>
        \\      <address type='usb' bus='0' port='1'/>
        \\    </input>
        \\    <input type='mouse' bus='ps2'/>
        \\    <input type='keyboard' bus='ps2'/>
        \\    <graphics type='spice' autoport='yes' listen='127.0.0.1'>
        \\      <listen type='address' address='127.0.0.1'/>
        \\      <image compression='off'/>
        \\    </graphics>
        \\    <sound model='ich9'>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x1b' function='0x0'/>
        \\    </sound>
        \\    <audio id='1' type='spice'/>
        \\    <video>
        \\      <model type='virtio' heads='1' primary='yes'/>
        \\      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x0'/>
        \\    </video>
        \\    <redirdev bus='usb' type='spicevmc'>
        \\      <address type='usb' bus='0' port='2'/>
        \\    </redirdev>
        \\    <redirdev bus='usb' type='spicevmc'>
        \\      <address type='usb' bus='0' port='3'/>
        \\    </redirdev>
        \\    <watchdog model='itco' action='reset'/>
        \\    <memballoon model='virtio'>
        \\      <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
        \\    </memballoon>
        \\    <rng model='virtio'>
        \\      <backend model='random'>/dev/urandom</backend>
        \\      <address type='pci' domain='0x0000' bus='0x06' slot='0x00' function='0x0'/>
        \\    </rng>
        \\  </devices>
        \\</domain>
    , .{ domain_name, dst_image, cloud_init_iso, mac_addr });
    // std.debug.print("{s}", .{xml});
    defer allocator.free(xml);

    // 6. Define and start domain
    const dom = c.virDomainDefineXML(conn, xml.ptr) orelse {
        std.log.err("Failed to define domain XML", .{});
        return error.DefineFailed;
    };
    defer _ = c.virDomainFree(dom);

    if (c.virDomainCreate(dom) < 0) {
        std.log.err("Failed to start domain", .{});
        return error.StartFailed;
    }
    std.log.info("Domain '{s}' created and started", .{domain_name});

    // 7. Wait for boot
    // 8. List running domains
    std.log.info("Running domains:", .{});
    const max_ids: i32 = 128;
    var ids: [128]i32 = undefined;
    const n = c.virConnectListDomains(conn, &ids, max_ids);
    for (ids[0..@intCast(n)]) |id| {
        if (c.virDomainLookupByID(conn, id)) |d| {
            defer _ = c.virDomainFree(d);
            const name = c.virDomainGetName(d);
            std.log.info("  {s}", .{name});
        }
    }

    // 9. Get IP address (try agent first, then lease)
    var ip_found: bool = false;
    var retry_count: u32 = 0;
    const max_retries: u32 = 30; // Wait up to 30 seconds

    std.log.info("Attempting to get IP for {s} (MAC: {s})...", .{ domain_name, mac_addr });
    while (!ip_found and retry_count < max_retries) : (retry_count += 1) {
        var ifaces: ?*c.virDomainInterfacePtr = null;
        var nifaces: i32 = 0;

        // Prefer agent
        nifaces = c.virDomainInterfaceAddresses(dom, &ifaces, c.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT, 0);
        if (nifaces <= 0) {
            // Fallback to lease (for NAT default network)
            nifaces = c.virDomainInterfaceAddresses(dom, &ifaces, c.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, 0);
        }

        if (nifaces <= 0 or ifaces == null) {
            // No interfaces found yet, wait and retry
            var ts: std.posix.timespec = .{ .sec = 1, .nsec = 0 };
            _ = std.posix.system.nanosleep(&ts, &ts);
            continue;
        }

        const iface_slice: [*]c.virDomainInterfacePtr = @ptrCast(ifaces.?);
        const count: usize = @intCast(nifaces);

        for (0..count) |idx| {
            const iface = iface_slice[idx].*;

            // Check if this interface matches our MAC address
            const iface_hwaddr = if (iface.hwaddr != null) mem.span(iface.hwaddr) else "";
            const mac_matches = mem.eql(u8, iface_hwaddr, mac_addr);

            for (0..@intCast(iface.naddrs)) |j| {
                const addr = iface.addrs[j];
                if (addr.type == c.VIR_IP_ADDR_TYPE_IPV4 or addr.type == c.VIR_IP_ADDR_TYPE_IPV6) {
                    // Only report IP if MAC address matches (to avoid showing wrong VM's IP)
                    if (mac_matches) {
                        std.log.info("  {s}: {s} (MAC: {s})", .{ iface.name, addr.addr, iface_hwaddr });
                        ip_found = true;
                    }
                }
            }
        }

        if (!ip_found) {
            var ts: std.posix.timespec = .{ .sec = 1, .nsec = 0 };
            _ = std.posix.system.nanosleep(&ts, &ts);
        }
    }

    if (!ip_found) {
        std.log.warn("Could not retrieve IP address after {d} attempts. VM is running but may need more time to boot.", .{max_retries});
    }
}
