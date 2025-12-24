//! By convention, root.zig is the root source file when making a library.
//! zm - A lightweight KVM/QEMU virtual machine creation tool

const std = @import("std");

// Public API exports
pub const config = @import("config.zig");
pub const vm = @import("vm.zig");
pub const cloudinit = @import("cloudinit.zig");
pub const libvirt = @import("libvirt.zig");
pub const network = @import("network.zig");

// Version information
pub const version = "0.2.0";

// Re-export commonly used types and functions
pub const Config = config.Config;
pub const VMSpecs = vm.VMSpecs;
pub const Connection = libvirt.Connection;
pub const Domain = libvirt.Domain;

// Convenience functions
pub const createVM = vm.createVM;
pub const deleteVM = vm.deleteVM;
pub const startVM = vm.startVM;
pub const stopVM = vm.stopVM;
pub const listVMs = vm.listVMs;
pub const showVMInfo = vm.showVMInfo;
pub const getVMIP = vm.getVMIP;
