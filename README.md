# zm

A lightweight KVM/QEMU virtual machine creation tool written in Zig.

## Usage

```bash
zm <domain-name>
```

Creates a new VM from a base image with automatic cloud-init configuration and displays its IP address.

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

## License

HGL General License - See COPYING file.
