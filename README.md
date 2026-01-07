# Server Patching Script

Automated server patching script for Proxmox VMs with comprehensive logging and error handling.

## Features

-   ✅ **Snapshot Management**: Automatically delete old and create new snapshots before patching
-   ✅ **Flexible Commands**: Define custom update commands per server
-   ✅ **Multi-OS Support**: Works with Ubuntu, CentOS, and any other Linux distribution
-   ✅ **Error Handling**: If a server fails, it's logged and the script continues to the next
-   ✅ **Detailed Logging**: Full logs with timestamps and colour-coded output
-   ✅ **Dry Run Mode**: Test your configuration without making changes
-   ✅ **Single Server Mode**: Patch individual servers for testing
-   ✅ **Enable/Disable Servers**: Temporarily exclude servers from patching

## Prerequisites

### On the machine running the script:

```bash
# Install required dependencies
sudo apt install jq openssh-client

# Install sshpass (only needed if using password authentication)
sudo apt install sshpass
```

### Authentication Setup:

The script supports two authentication methods:

1. **SSH Key** (recommended) - More secure, no passwords in config
2. **Password** - Useful when SSH keys aren't an option

#### Option 1: SSH Key Authentication (Recommended)

```bash
# Generate SSH key if you don't have one
ssh-keygen -t rsa -b 4096

# Copy key to Proxmox hosts
ssh-copy-id root@pve1-ip
ssh-copy-id root@pve2-ip
ssh-copy-id root@pve3-ip

# Copy key to all VMs
ssh-copy-id admin@server1-ip
ssh-copy-id admin@server2-ip
# ... repeat for all servers
```

#### Option 2: Password Authentication

-   Install `sshpass`: `sudo apt install sshpass`
-   Set `auth_method` to `"password"` in the config
-   Provide the password in the `password` field
-   **Security Note**: Passwords are stored in plain text in the config file

## Configuration

Edit `servers.json` to configure your environment:

### Settings Section

```json
{
    "settings": {
        "ssh_timeout": 30,
        "ssh_options": "-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes",
        "snapshot_name": "server_patching",
        "log_dir": "./logs"
    }
}
```

### Proxmox Hosts Section

```json
{
    "proxmox_hosts": {
        "pve1": {
            "host": "192.168.1.10",
            "user": "root",
            "auth_method": "key",
            "ssh_key": "~/.ssh/id_rsa",
            "password": null
        },
        "pve2": {
            "host": "192.168.1.11",
            "user": "root",
            "auth_method": "password",
            "ssh_key": null,
            "password": "your-password-here"
        }
    }
}
```

### Servers Section

Each server entry supports:

| Field             | Description                                | Required          |
| ----------------- | ------------------------------------------ | ----------------- |
| `name`            | Unique identifier for the server           | Yes               |
| `vmid`            | Proxmox VM ID                              | Yes               |
| `proxmox_host`    | Key from `proxmox_hosts` section           | Yes               |
| `ip`              | Server IP address                          | Yes               |
| `user`            | SSH username                               | Yes               |
| `auth_method`     | `"key"` or `"password"` (default: `"key"`) | No                |
| `ssh_key`         | Path to SSH private key (for key auth)     | If using key      |
| `password`        | SSH password (for password auth)           | If using password |
| `os_type`         | Operating system (informational)           | No                |
| `update_commands` | Array of commands to execute               | Yes               |
| `enabled`         | Whether to process this server             | Yes               |
| `comment`         | Notes (ignored by script)                  | No                |

#### Example: Ubuntu Server with SSH Key

```json
{
    "name": "web-server-01",
    "vmid": 100,
    "proxmox_host": "pve1",
    "ip": "192.168.1.20",
    "user": "admin",
    "auth_method": "key",
    "ssh_key": "~/.ssh/id_rsa",
    "password": null,
    "os_type": "ubuntu",
    "update_commands": [
        "sudo apt update",
        "sudo apt upgrade -y",
        "sudo reboot now"
    ],
    "enabled": true
}
```

#### Example: Ubuntu Server with Password

```json
{
    "name": "web-server-02",
    "vmid": 101,
    "proxmox_host": "pve1",
    "ip": "192.168.1.21",
    "user": "admin",
    "auth_method": "password",
    "ssh_key": null,
    "password": "my-secure-password",
    "os_type": "ubuntu",
    "update_commands": [
        "sudo apt update",
        "sudo apt upgrade -y",
        "sudo reboot now"
    ],
    "enabled": true
}
```

#### Example: CentOS Server

```json
{
    "name": "legacy-centos-01",
    "vmid": 200,
    "proxmox_host": "pve2",
    "ip": "192.168.1.30",
    "user": "admin",
    "auth_method": "key",
    "ssh_key": "~/.ssh/id_rsa",
    "password": null,
    "os_type": "centos",
    "update_commands": [
        "sudo yum makecache",
        "sudo yum update -y",
        "sudo reboot now"
    ],
    "enabled": true
}
```

#### Example: Custom Commands (No Reboot)

```json
{
    "name": "critical-server",
    "vmid": 300,
    "proxmox_host": "pve3",
    "ip": "192.168.1.40",
    "user": "admin",
    "auth_method": "key",
    "ssh_key": "~/.ssh/id_rsa",
    "password": null,
    "os_type": "ubuntu",
    "update_commands": [
        "sudo apt update",
        "sudo apt upgrade -y",
        "echo 'Updates installed, reboot scheduled for maintenance window'"
    ],
    "enabled": true
}
```

## Usage

### Basic Usage

```bash
# Run full patching on all enabled servers
./server-patching.sh

# Dry run - see what would happen without making changes
./server-patching.sh --dry-run

# Patch a single server
./server-patching.sh --server web-server-01

# Use a different config file
./server-patching.sh --config /path/to/other-servers.json
```

### Advanced Options

```bash
# Skip snapshot operations (just run updates)
./server-patching.sh --skip-snapshots

# Skip updates (just manage snapshots)
./server-patching.sh --skip-updates

# Combine options
./server-patching.sh --dry-run --server web-server-01
```

### All Options

```
Usage: server-patching.sh [OPTIONS]

OPTIONS:
    -c, --config FILE       Use specified config file (default: servers.json)
    -s, --server NAME       Process only specified server
    -d, --dry-run           Show what would be done without executing
    --skip-snapshots        Skip snapshot operations
    --skip-updates          Skip update commands
    -h, --help              Show help message
    -v, --version           Show version information
```

## Logging

Logs are stored in the `logs/` directory:

-   `patching_YYYYMMDD_HHMMSS.log` - Full detailed log
-   `summary_YYYYMMDD_HHMMSS.txt` - Summary of results

### Log Output

```
═══════════════════════════════════════════════════════════════
  Processing: web-server-01
═══════════════════════════════════════════════════════════════

[2025-01-07 10:30:15] Server details:
[2025-01-07 10:30:15]   VM ID: 100
[2025-01-07 10:30:15]   Proxmox Host: pve1
[2025-01-07 10:30:15]   IP: 192.168.1.20
[2025-01-07 10:30:16] → Checking for existing snapshot 'server_patching' on VM 100
[2025-01-07 10:30:17] → Deleting existing snapshot 'server_patching' on VM 100
[2025-01-07 10:30:25] ✓ Deleted old snapshot for web-server-01
[2025-01-07 10:30:26] → Creating snapshot 'server_patching' for VM 100
[2025-01-07 10:30:45] ✓ Created new snapshot for web-server-01
[2025-01-07 10:30:46] → Executing: sudo apt update
[2025-01-07 10:30:55] ✓ Command completed: sudo apt update
[2025-01-07 10:30:56] → Executing: sudo apt upgrade -y
[2025-01-07 10:32:30] ✓ Command completed: sudo apt upgrade -y
[2025-01-07 10:32:31] → Executing: sudo reboot now
[2025-01-07 10:32:32] ✓ Reboot command sent
[2025-01-07 10:32:32] ✓ Completed processing: web-server-01
```

## Workflow

1. **Delete Old Snapshot**: Removes the previous `server_patching` snapshot (if exists)
2. **Create New Snapshot**: Creates a fresh snapshot before updates
3. **Run Update Commands**: Executes each command in sequence
4. **Continue to Next Server**: Moves to the next server (or fails gracefully)

If any step fails, the server is added to the failed list and the script continues.

## Summary Output

At the end of patching:

```
═══════════════════════════════════════════════════════════════
  PATCHING SUMMARY
═══════════════════════════════════════════════════════════════

━━━ SUCCESSFUL (18) ━━━
  ✓ web-server-01
  ✓ web-server-02
  ✓ db-server-01
  ...

━━━ SKIPPED (1) ━━━
  ○ disabled-example (disabled)

━━━ FAILED (1) ━━━
  ✗ legacy-server (snapshot creation failed)

⚠ ATTENTION: The above servers require manual intervention!

Full log: ./logs/patching_20250107_103000.log
Summary: ./logs/summary_20250107_103000.txt
```

## Tips

### Testing Before Full Run

```bash
# 1. First, do a dry run
./server-patching.sh --dry-run

# 2. Test on a single non-critical server
./server-patching.sh --server test-server

# 3. If all looks good, run the full patching
./server-patching.sh
```

### Adding New Servers

1. Open `servers.json`
2. Add a new entry to the `servers` array
3. Set `enabled: true` when ready

### Temporarily Disabling Servers

Set `"enabled": false` in the server's config - it will be skipped and listed in the summary.

### Password Authentication

If you must use password auth instead of SSH keys, you can:

1. Install `sshpass`: `sudo apt install sshpass`
2. Modify the script's SSH commands (not recommended for security)

Better approach: Set up SSH key authentication for all servers.

## Troubleshooting

### "Permission denied" errors

-   For key auth: Ensure SSH keys are properly set up
-   For password auth: Verify the password is correct
-   Check the user has sudo privileges without password (for update commands)
-   Verify Proxmox user has snapshot permissions

### "sshpass: command not found"

-   Install sshpass: `sudo apt install sshpass`
-   Only required if using password authentication

### Snapshot operations fail

-   Ensure VM IDs are correct
-   Verify the Proxmox user (usually root) can access the VMs
-   Check if there's enough storage space for snapshots

### Commands timeout

-   Increase `ssh_timeout` in settings
-   For slow updates, the script uses 600s timeout for commands

### Connection refused

-   Verify IP addresses are correct
-   Check firewall rules allow SSH
-   Ensure servers are running

### Password auth not working

-   Ensure sshpass is installed
-   Check for special characters in password (may need escaping)
-   Verify `auth_method` is set to `"password"`

## Security Notes

-   Store this script and config on a secure machine
-   **SSH keys are strongly recommended** over passwords
-   If using password auth:
    -   Passwords are stored in plain text in `servers.json`
    -   Restrict file permissions: `chmod 600 servers.json`
    -   Consider encrypting the config file when not in use
-   Regularly rotate SSH keys and passwords
-   Review the commands in your config before running
-   Consider using a secrets manager for production environments

## Cron Job (Optional)

To run monthly patching automatically:

```bash
# Edit crontab
crontab -e

# Add line to run on first Saturday of each month at 2 AM
0 2 1-7 * 6 /path/to/server-patching/server-patching.sh >> /path/to/server-patching/logs/cron.log 2>&1
```

**Note**: Consider the implications of automated reboots before setting up cron.
