const std = @import("std");
const fs = std.fs;
const c = @cImport({
    @cInclude("libvirt/libvirt.h");
});
const config = @import("config.zig");
const cloudinit = @import("cloudinit.zig");
const libvirt = @import("libvirt.zig");
const network = @import("network.zig");

pub const VMSpecs = struct {
    memory: u64 = 1024 * 1024, // in KiB
    vcpus: u32 = 2,
    machine: []const u8 = "pc-q35-10.0",
    disk_size: ?u64 = null, // in bytes
    image_path: ?[]const u8 = null,
    start: bool = true,
    wait_for_ip: bool = true,
};

pub const VMError = error{
    ImageCopyFailed,
    PermissionChangeFailed,
    InvalidDomainName,
    VMAlreadyExists,
};

pub fn createVM(
    allocator: std.mem.Allocator,
    conn: *const libvirt.Connection,
    cfg: *const config.Config,
    domain_name: []const u8,
    specs: VMSpecs,
) !void {
    // Validate domain name
    if (domain_name.len == 0) return VMError.InvalidDomainName;

    // Check if domain already exists
    if (conn.lookupDomain(allocator, domain_name)) |_| {
        return VMError.VMAlreadyExists;
    } else |_| {}

    const src_image = specs.image_path orelse try std.fs.path.join(allocator, &.{ cfg.base_image_path, "zamin" });
    defer if (specs.image_path == null) allocator.free(src_image);

    const dst_image = try std.fmt.allocPrint(allocator, "{s}/{s}.qcow2", .{ cfg.vm_storage_path, domain_name });
    defer allocator.free(dst_image);

    // 1. Copy the source image
    std.log.info("Copying image {s} -> {s}", .{ src_image, dst_image });
    try fs.cwd().copyFile(src_image, fs.cwd(), dst_image, .{});

    // 2. Fix ownership and permissions
    const stat = try fs.cwd().statFile(dst_image);
    if (stat.mode & 0o666 != 0o660) {
        const file = try fs.cwd().openFile(dst_image, .{});
        defer file.close();
        try file.chmod(0o660);
    }

    // 3. Create cloud-init ISO
    const cloud_init_template = try std.fs.path.join(allocator, &.{ cfg.cloud_init_template_path, "cloud-init-user-data.yaml" });
    defer allocator.free(cloud_init_template);

    const cloud_init_iso = try std.fmt.allocPrint(allocator, "/tmp/{s}-cloud-init.iso", .{domain_name});
    defer allocator.free(cloud_init_iso);

    std.log.info("Creating cloud-init ISO at {s}", .{cloud_init_iso});
    try cloudinit.createCloudInitISO(allocator, domain_name, cloud_init_template, cloud_init_iso);

    // 4. Generate MAC address
    const mac_addr = network.generateMACAddress(domain_name);

    // 5. Generate domain XML
    const xml = try generateDomainXML(allocator, domain_name, dst_image, cloud_init_iso, mac_addr, specs);
    defer allocator.free(xml);

    // 6. Define domain
    std.log.info("Defining domain '{s}'", .{domain_name});
    const dom = try libvirt.Domain.defineXML(conn, allocator, xml);
    defer dom.free();

    // 7. Start domain if requested
    if (specs.start) {
        std.log.info("Starting domain '{s}'", .{domain_name});
        try dom.create();
        std.log.info("Domain '{s}' created and started", .{domain_name});

        // 8. Wait for IP if requested
        if (specs.wait_for_ip) {
            const ip = network.getIPAddress(&dom, allocator, &mac_addr, cfg.max_retries) catch |err| {
                std.log.warn("Could not retrieve IP address: {}", .{err});
                return;
            };
            defer allocator.free(ip);
            std.log.info("VM IP address: {s}", .{ip});
        }
    } else {
        std.log.info("Domain '{s}' created but not started", .{domain_name});
    }
}

pub fn deleteVM(
    allocator: std.mem.Allocator,
    conn: *const libvirt.Connection,
    cfg: *const config.Config,
    domain_name: []const u8,
    force: bool,
) !void {
    const dom = try conn.lookupDomain(allocator, domain_name);
    defer dom.free();

    // Stop if running
    if (dom.isActive()) {
        if (force) {
            std.log.info("Force stopping domain '{s}'", .{domain_name});
            try dom.destroy();
        } else {
            std.log.err("Domain '{s}' is running. Use --force to stop and delete.", .{domain_name});
            return error.VMRunning;
        }
    }

    // Undefine domain
    std.log.info("Undefining domain '{s}'", .{domain_name});
    try dom.undefine();

    // Delete disk image
    const disk_path = try std.fmt.allocPrint(allocator, "{s}/{s}.qcow2", .{ cfg.vm_storage_path, domain_name });
    defer allocator.free(disk_path);

    fs.cwd().deleteFile(disk_path) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Could not delete disk image: {}", .{err});
        }
    };

    std.log.info("Domain '{s}' deleted", .{domain_name});
}

pub fn startVM(
    allocator: std.mem.Allocator,
    conn: *const libvirt.Connection,
    domain_name: []const u8,
) !void {
    const dom = try conn.lookupDomain(allocator, domain_name);
    defer dom.free();

    if (dom.isActive()) {
        std.log.info("Domain '{s}' is already running", .{domain_name});
        return;
    }

    std.log.info("Starting domain '{s}'", .{domain_name});
    try dom.create();
    std.log.info("Domain '{s}' started", .{domain_name});
}

pub fn stopVM(
    allocator: std.mem.Allocator,
    conn: *const libvirt.Connection,
    domain_name: []const u8,
    force: bool,
) !void {
    const dom = try conn.lookupDomain(allocator, domain_name);
    defer dom.free();

    if (!dom.isActive()) {
        std.log.info("Domain '{s}' is not running", .{domain_name});
        return;
    }

    if (force) {
        std.log.info("Force stopping domain '{s}'", .{domain_name});
        try dom.destroy();
    } else {
        // Graceful shutdown via ACPI
        std.log.info("Gracefully stopping domain '{s}'", .{domain_name});
        if (c.virDomainShutdown(@ptrCast(dom.dom)) < 0) {
            return error.ShutdownFailed;
        }
    }

    std.log.info("Domain '{s}' stopped", .{domain_name});
}

pub fn getVMIP(
    allocator: std.mem.Allocator,
    conn: *const libvirt.Connection,
    cfg: *const config.Config,
    domain_name: []const u8,
) !void {
    const dom = try conn.lookupDomain(allocator, domain_name);
    defer dom.free();

    if (!dom.isActive()) {
        std.log.err("Domain '{s}' is not running", .{domain_name});
        return error.VMNotRunning;
    }

    const mac_addr = network.generateMACAddress(domain_name);
    const ip = network.getIPAddress(&dom, allocator, &mac_addr, cfg.max_retries) catch |err| {
        std.log.warn("Could not retrieve IP address: {}", .{err});
        return;
    };
    defer allocator.free(ip);

    std.log.info("{s}: {s}", .{ domain_name, ip });
}

pub fn listVMs(
    allocator: std.mem.Allocator,
    conn: *const libvirt.Connection,
) !void {
    const domains = try conn.listDomains(allocator);
    defer {
        for (domains) |name| allocator.free(name);
        allocator.free(domains);
    }

    if (domains.len == 0) {
        std.log.info("No running domains", .{});
        return;
    }

    std.log.info("Running domains:", .{});
    for (domains) |name| {
        std.log.info("  {s}", .{name});
    }
}

pub fn showVMInfo(
    alloc: std.mem.Allocator,
    conn: *const libvirt.Connection,
    domain_name: []const u8,
) !void {
    const dom = try conn.lookupDomain(alloc, domain_name);
    defer dom.free();

    std.log.info("Domain: {s}", .{dom.getName()});
    std.log.info("  Active: {s}", .{if (dom.isActive()) "yes" else "no"});

    // const state = dom.getState() catch "unknown";
    // std.log.info("  State: {s}", .{@tagName(state)});
}

fn generateDomainXML(
    allocator: std.mem.Allocator,
    domain_name: []const u8,
    disk_path: []const u8,
    iso_path: []const u8,
    mac_addr: [17]u8,
    specs: VMSpecs,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<domain type='kvm'>
        \\  <name>{s}</name>
        \\  <metadata>
        \\    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
        \\      <libosinfo:os id="http://debian.org/debian/12"/>
        \\    </libosinfo:libosinfo>
        \\  </metadata>
        \\  <memory unit='KiB'>{d}</memory>
        \\  <currentMemory unit='KiB'>{d}</currentMemory>
        \\  <vcpu placement='static'>{d}</vcpu>
        \\  <resource>
        \\    <partition>/machine</partition>
        \\  </resource>
        \\  <sysinfo type='smbios'>
        \\    <system>
        \\      <entry name='serial'>ds=nocloud</entry>
        \\    </system>
        \\  </sysinfo>
        \\  <os>
        \\    <type arch='x86_64' machine='{s}'>hvm</type>
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
    , .{ domain_name, specs.memory, specs.memory, specs.vcpus, specs.machine, disk_path, iso_path, &mac_addr });
}
