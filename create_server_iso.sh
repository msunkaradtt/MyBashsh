#!/bin/bash

# Script to create a bootable ISO image of a Linux server with RAID1 and safety checks

# Exit on any error
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration (adjust these as needed)
DISK="/dev/sda" # Disk to backup (RAID1 member)
OUTPUT_DIR="/mnt/localdisk" # Directory to store the ISO (must not be on /dev/sda or /dev/sdb)
ISO_NAME="server_backup_$(date +%Y%m%d_%H%M%S).iso"
RAW_IMAGE="raw_backup.img"
COMPRESSED_IMAGE="raw_backup.img.gz"
MIN_SPACE_GB=10 # Minimum free space required in GB
MOUNT_CHECK="/proc/mounts"

# Function to log messages
log_message() {
    echo -e "${2}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_message "This script must be run as root. Exiting." "${RED}"
    exit 1
fi

# Check if required tools are installed
for tool in dd mkisofs gzip mdadm; do
    if ! command -v $tool &>/dev/null; then
        log_message "$tool is not installed. Please install it (e.g., 'apt install $tool' or 'yum install $tool')." "${RED}"
        exit 1
    fi
done

# Check RAID status
if [[ -f /proc/mdstat ]]; then
    log_message "Checking RAID status..." "${GREEN}"
    cat /proc/mdstat
    if ! grep -q "active.*raid1" /proc/mdstat; then
        log_message "Warning: RAID1 arrays may not be in a healthy state. Check '/proc/mdstat'." "${YELLOW}"
        read -p "Continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_message "Aborting at user request." "${RED}"
            exit 1
        fi
    fi
else
    log_message "RAID not detected. Is this a RAID system?" "${YELLOW}"
fi

# Check if output directory exists and is writable
if [[ ! -d "$OUTPUT_DIR" ]]; then
    log_message "Output directory $OUTPUT_DIR does not exist. Creating it..." "${YELLOW}"
    mkdir -p "$OUTPUT_DIR" || {
        log_message "Failed to create $OUTPUT_DIR. Exiting." "${RED}"
        exit 1
    }
fi
if [[ ! -w "$OUTPUT_DIR" ]]; then
    log_message "Output directory $OUTPUT_DIR is not writable. Exiting." "${RED}"
    exit 1
fi

# Check if output directory is on the disk being backed up
if df "$OUTPUT_DIR" | grep -qE "/dev/sda|/dev/sdb"; then
    log_message "Error: Output directory $OUTPUT_DIR is on $DISK or /dev/sdb. Choose a different disk (e.g., external drive)." "${RED}"
    exit 1
fi

# Check if disk exists
if [[ ! -b "$DISK" ]]; then
    log_message "Disk $DISK does not exist. Exiting." "${RED}"
    exit 1
fi

# Check if disk is mounted
if grep -qs "$DISK" "$MOUNT_CHECK"; then
    log_message "Warning: $DISK or its partitions are mounted. This may cause data corruption in the backup." "${YELLOW}"
    log_message "For a clean backup, boot from a live CD/USB (e.g., SystemRescueCD) or stop services and unmount partitions." "${YELLOW}"
    read -p "Continue anyway? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_message "Aborting at user request." "${RED}"
        exit 1
    fi
fi

# Check for running services that may cause data changes
if pgrep -x "mysql" >/dev/null || pgrep -x "postgres" >/dev/null || pgrep -x "apache2" >/dev/null || pgrep -x "nginx" >/dev/null; then
    log_message "Warning: Active services (e.g., databases, web servers) detected. This may lead to inconsistent backup." "${YELLOW}"
    log_message "Consider stopping services (e.g., 'systemctl stop mysql apache2') or using a live CD/USB." "${YELLOW}"
    read -p "Continue anyway? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_message "Aborting at user request." "${RED}"
        exit 1
    fi
fi

# Check available space in output directory
DISK_SIZE=$(lsblk -b --output SIZE -n -d "$DISK" | head -n 1)
DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
REQUIRED_SPACE_GB=$((DISK_SIZE_GB + MIN_SPACE_GB))
AVAILABLE_SPACE=$(df -B1G "$OUTPUT_DIR" | tail -n 1 | awk '{print $4}')
if [[ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE_GB" ]]; then
    log_message "Insufficient space in $OUTPUT_DIR. Need ${REQUIRED_SPACE_GB}GB, but only ${AVAILABLE_SPACE}GB available." "${RED}"
    exit 1
fi
log_message "Sufficient space available: ${AVAILABLE_SPACE}GB in $OUTPUT_DIR." "${GREEN}"

# Create raw disk image
log_message "Creating raw disk image from $DISK..." "${GREEN}"
dd if="$DISK" of="$OUTPUT_DIR/$RAW_IMAGE" bs=4M status=progress || {
    log_message "Failed to create raw disk image." "${RED}"
    exit 1
}

# Compress the raw image
log_message "Compressing raw image to save space..." "${GREEN}"
gzip "$OUTPUT_DIR/$RAW_IMAGE" || {
    log_message "Failed to compress image." "${RED}"
    exit 1
}

# Create bootable ISO
log_message "Creating bootable ISO image..." "${GREEN}"
mkisofs -o "$OUTPUT_DIR/$ISO_NAME" -b "$COMPRESSED_IMAGE" -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table "$OUTPUT_DIR/$COMPRESSED_IMAGE" || {
    log_message "Failed to create ISO image." "${RED}"
    exit 1
}

# Verify ISO integrity
log_message "Verifying ISO image..." "${GREEN}"
if [[ -f "$OUTPUT_DIR/$ISO_NAME" ]]; then
    ISO_SIZE=$(stat -c %s "$OUTPUT_DIR/$ISO_NAME")
    if [[ "$ISO_SIZE" -gt 0 ]]; then
        log_message "ISO image created successfully: $OUTPUT_DIR/$ISO_NAME (Size: ${ISO_SIZE} bytes)" "${GREEN}"
    else
        log_message "ISO image is empty or corrupted." "${RED}"
        exit 1
    fi
else
    log_message "ISO image not found." "${RED}"
    exit 1
fi

# Clean up temporary files
log_message "Cleaning up temporary files..." "${GREEN}"
rm -f "$OUTPUT_DIR/$COMPRESSED_IMAGE" || log_message "Warning: Failed to remove temporary file $COMPRESSED_IMAGE." "${YELLOW}"

log_message "Backup complete! ISO saved to $OUTPUT_DIR/$ISO_NAME" "${GREEN}"
log_message "Next steps:" "${YELLOW}"
log_message "1. Test the ISO in a virtual machine (e.g., VirtualBox, QEMU) to ensure it boots correctly." "${YELLOW}"
log_message "2. Store the ISO securely, preferably encrypted (e.g., 'gpg -c $ISO_NAME')." "${YELLOW}"
log_message "3. To restore, boot from the ISO and use 'dd' to write it back to a disk. Rebuild RAID1 using 'mdadm' if needed." "${YELLOW}"
log_message "4. Note: Restoring to a single disk will include RAID metadata. To restore RAID1, ensure both disks are configured with 'mdadm'." "${YELLOW}"

exit 0