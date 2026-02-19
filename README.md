<p align="center">
  <img src="assets/logo.svg" alt="ZM Logo" width="300">
</p>

# zm

A lightweight KVM/QEMU virtual machine creation tool written in Zig.

## Features

- Create and manage KVM/QEMU virtual machines
- Automatic cloud-init configuration with ISO generation
- IP address detection for running VMs
- Configurable VM specifications (memory, vCPUs, machine type)
- Support for custom base images
- Clean modular architecture

## Installation

### Dependencies

- Zig (latest stable)
- libvirt development libraries
- libisofs, libisoburn, libburn libraries

On Debian/Ubuntu:
```bash
sudo apt install zig libvirt-dev libisofs-dev libisoburn-dev libburn-dev
```

On Arch Linux:
```bash
sudo pacman -S zig libvirt libisofs libisoburn libburn
```

### Build

```bash
zig build -Doptimize=ReleaseFast
sudo zig build install
```

### Configuration

Create a configuration file at `/etc/zm/config` or `~/.config/zm/config`:

```
base_image_path=/usr/share/zm/images
vm_storage_path=/var/lib/libvirt/images
cloud_init_template_path=/usr/share/zm/images/cloud-init
default_memory=1048576
default_vcpus=2
default_machine=pc-q35-10.0
max_retries=30
```

### Setting Up Base Images

Create the images directory and add your base VM image:

```bash
sudo mkdir -p /usr/share/zm/images
sudo mkdir -p /usr/share/zm/images/cloud-init
```

Download and extract ZAmin cloud image:
```bash
sudo wget -P /usr/share/zm/images/ \
  https://archive.evgnomon.org/zamin/zamin-0.0.1.tar.gz
sudo tar -xzf /usr/share/zm/images/zamin-0.0.1.tar.gz -C /usr/share/zm/images/
```


Create the cloud-init user-data template:
```bash
sudo tee /usr/share/zm/images/cloud-init/cloud-init-user-data.yaml << 'EOF'
#cloud-config
users:
  - name: user
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-rsa YOUR_PUBLIC_KEY_HERE
EOF
```

Replace `YOUR_PUBLIC_KEY_HERE` with your actual SSH public key from `~/.ssh/id_rsa.pub`.

## Usage

### Basic Usage

Create a new VM (legacy mode):
```bash
zm myvm
```

### Commands

#### Create a VM
```bash
zm create myvm
```

With custom specifications:
```bash
zm create myvm --memory 2GiB --vcpus 4
zm create myvm --machine pc-q35-9.0
zm create myvm --image /path/to/custom/image.qcow2
```

Create but don't start:
```bash
zm create myvm --no-start
```

Don't wait for IP address:
```bash
zm create myvm --no-wait-ip
```

#### List VMs
```bash
zm list
```

#### Show VM Information
```bash
zm info myvm
```

#### Start a VM
```bash
zm start myvm
```

#### Stop a VM
```bash
zm stop myvm
```

Force stop (poweroff):
```bash
zm stop myvm --force
```

#### Delete a VM
```bash
zm delete myvm
```

Force delete a running VM:
```bash
zm delete myvm --force
```

#### Get VM IP Address
```bash
zm ip myvm
```

### Global Options

- `--help, -h` - Show help message
- `--version, -v` - Show version information

### Examples

Create a web server VM:
```bash
zm create webserver --memory 2GiB --vcpus 2
zm ip webserver
```

Create multiple VMs:
```bash
zm create db1 --memory 4GiB --vcpus 4
zm create db2 --memory 4GiB --vcpus 4
zm create app1 --memory 1GiB --vcpus 2
```

Manage VMs:
```bash
zm list
zm info webserver
zm stop webserver
zm start webserver
```

## Architecture

The project is organized into modular components:

- `src/config.zig` - Configuration management
- `src/cloudinit.zig` - Cloud-init ISO generation
- `src/libvirt.zig` - Libvirt connection and operations
- `src/network.zig` - Network and IP address detection
- `src/vm.zig` - VM creation and management
- `src/main.zig` - CLI interface
- `src/root.zig` - Library exports

## Library Usage

zm can also be used as a Zig library:

```zig
const zm = @import("zm");

const allocator = std.heap.page_allocator;
const conn = try zm.Connection.open("qemu:///system");
defer conn.close();

const cfg = zm.Config.init();
const specs = zm.VMSpecs{
    .memory = 2 * 1024 * 1024, // 2GiB
    .vcpus = 4,
};

try zm.createVM(allocator, &conn, &cfg, "myvm", specs);
```

## Troubleshooting

### Permission Denied

Make sure you have proper permissions to access libvirt:
```bash
sudo usermod -a -G libvirt $USER
sudo usermod -a -G kvm $USER
```

### VM Not Getting IP

Check that the default network is active:
```bash
virsh net-list --all
virsh net-start default
virsh net-autostart default
```

### Cloud-init Not Working

Ensure cloud-init is installed in your base image and the template file exists:
```bash
ls /usr/share/zm/images/cloud-init/cloud-init-user-data.yaml
```

## Contributing

Contributions are welcome! Please ensure your code follows the project's style and includes tests where appropriate.

## License

HGL General License - See COPYING file.
