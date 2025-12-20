# mkvm

A lightweight KVM/QEMU virtual machine creation tool written in Zig.

## Usage

```bash
mkvm <domain-name>
```

Creates a new VM from a base image with automatic cloud-init configuration and displays its IP address.

## Requirements

- libvirt
- QEMU/KVM
- genisoimage
- Base image at `/usr/share/mkvm/images/zamin`

## Build

```bash
zig build
```

## License

HGL General License - See COPYING file.
