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

# Function to check if a file is a valid gzip
check_gzip_integrity() {
    local file="$1"
    if [[ -f "$file" ]]; then
        log_message "Starting gzip integrity check for $file..." "${GREEN}"
        start_time=$(date +%s)
        if gzip -t "$file" 2>/dev/null; then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            log_message "Gzip file $file is valid. Verification took $duration seconds." "${GREEN}"
            return 0
        else
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            log_message "Gzip file $file is incomplete or corrupted. Verification took $duration seconds. Removing..." "${YELLOW}"
            rm -f "$file"
            return 1
        fi
    fi
    return 1
}

# Function to check raw image size
check_raw_image_size() {
    local raw_file="$1"
    local disk_size=$(lsblk -b --output SIZE -n -d "$DISK" | head -n 1)
    local raw_size=$(stat -c %s "$raw_file" 2>/dev/null || echo 0)
    if [[ "$raw_size" -eq "$disk_size" ]]; then
        log_message "Raw image $raw_file matches disk size ($disk_size bytes). Proceeding with compression." "${GREEN}"
        return 0
    else
        log_message "Raw image $raw_file size ($raw_size bytes) does not match disk size ($disk_size bytes). Recreating raw image." "${YELLOW}"
        rm -f "$raw_file"
        return 1
    fi
}

# Step 1: Check if running as root
log_message "Step 1: Verifying root privileges..." "${GREEN}"
if [[ $EUID -ne 0 ]]; then
    log_message "This script must be run as root. Exiting." "${RED}"
    exit 1
fi
log_message "Root privileges confirmed." "${GREEN}"

# Step 2: Check if required tools are installed
log_message "Step 2: Checking for required tools..." "${GREEN}"
for tool in dd genisoimage gzip mdadm pv; do
    if ! command -v $tool &>/dev/null; then
        log_message "$tool is not installed. Please install it (e.g., 'apt install $tool')." "${RED}"
        exit 1
    fi
done
log_message "All required tools are installed." "${GREEN}"

# Step 3: Check RAID status
log_message "Step 3: Checking RAID status..." "${GREEN}"
if [[ -f /proc/mdstat ]]; then
    log_message "RAID configuration detected. Displaying status:" "${GREEN}"
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
log_message "RAID status check complete." "${GREEN}"

# Step 4: Check if output directory exists and is writable
log_message "Step 4: Verifying output directory $OUTPUT_DIR..." "${GREEN}"
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
log_message "Output directory $OUTPUT_DIR is ready." "${GREEN}"

# Step 5: Check if output directory is on the disk being backed up
log_message "Step 5: Ensuring output directory is not on $DISK or /dev/sdb..." "${GREEN}"
if df "$OUTPUT_DIR" | grep -qE "/dev/sda|/dev/sdb"; then
    log_message "Error: Output directory $OUTPUT_DIR is on $DISK or /dev/sdb. Choose a different disk (e.g., external drive)." "${RED}"
    exit 1
fi
log_message "Output directory is on a separate disk." "${GREEN}"

# Step 6: Check if disk exists
log_message "Step 6: Verifying disk $DISK exists..." "${GREEN}"
if [[ ! -b "$DISK" ]]; then
    log_message "Disk $DISK does not exist. Exiting." "${RED}"
    exit 1
fi
log_message "Disk $DISK confirmed." "${GREEN}"

# Step 7: Check if disk is mounted
log_message "Step 7: Checking if $DISK is mounted..." "${GREEN}"
if grep -qs "$DISK" "$MOUNT_CHECK"; then
    log_message "Warning: $DISK or its partitions are mounted. This may cause data corruption in the backup." "${YELLOW}"
    log_message "For a cleaner backup, boot from a live CD/USB (e.g., SystemRescueCD) or stop services and unmount partitions." "${YELLOW}"
    read -p "Continue anyway? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_message "Aborting at user request." "${RED}"
        exit 1
    fi
fi
log_message "Disk mount check complete." "${GREEN}"

# Step 8: Check for running services
log_message "Step 8: Checking for active services..." "${GREEN}"
if pgrep -x "mysql" >/dev/null || pgrep -x "postgres" >/dev/null || pgrep -x "apache2" >/dev/null || pgrep -x "nginx" >/dev/null; then
    log_message "Warning: Active services (e.g., databases, web servers) detected. This may lead to inconsistent backup." "${YELLOW}"
    log_message "Consider stopping services (e.g., 'systemctl stop mysql apache2') or using a live CD/USB." "${YELLOW}"
    read -p "Continue anyway? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_message "Aborting at user request." "${RED}"
        exit 1
    fi
fi
log_message "Service check complete." "${GREEN}"

# Step 9: Check available space in output directory
log_message "Step 9: Checking available space in $OUTPUT_DIR..." "${GREEN}"
DISK_SIZE=$(lsblk -b --output SIZE -n -d "$DISK" | head -n 1)
DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
REQUIRED_SPACE_GB=$((DISK_SIZE_GB + MIN_SPACE_GB))
AVAILABLE_SPACE=$(df -B1G "$OUTPUT_DIR" | tail -n 1 | awk '{print $4}')
if [[ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE_GB" ]]; then
    log_message "Insufficient space in $OUTPUT_DIR. Need ${REQUIRED_SPACE_GB}GB, but only ${AVAILABLE_SPACE}GB available." "${RED}"
    exit 1
fi
log_message "Sufficient space available: ${AVAILABLE_SPACE}GB in $OUTPUT_DIR." "${GREEN}"

# Step 10: Check for existing raw image
log_message "Step 10: Checking for existing raw image $OUTPUT_DIR/$RAW_IMAGE..." "${GREEN}"
if [[ -f "$OUTPUT_DIR/$RAW_IMAGE" ]]; then
    log_message "Raw image $OUTPUT_DIR/$RAW_IMAGE exists. Verifying size..." "${YELLOW}"
    if check_raw_image_size "$OUTPUT_DIR/$RAW_IMAGE"; then
        log_message "Existing raw image is valid. Skipping raw image creation." "${GREEN}"
        RAW_IMAGE_EXISTS=1
    else
        log_message "Existing raw image is invalid. Will recreate it." "${YELLOW}"
    fi
else
    log_message "No existing raw image found." "${GREEN}"
fi

# Step 11: Check for existing compressed image and verify integrity
log_message "Step 11: Checking for existing compressed image $OUTPUT_DIR/$COMPRESSED_IMAGE..." "${GREEN}"
if [[ -f "$OUTPUT_DIR/$COMPRESSED_IMAGE" ]]; then
    log_message "Compressed image $OUTPUT_DIR/$COMPRESSED_IMAGE exists. Verifying integrity..." "${YELLOW}"
    if check_gzip_integrity "$OUTPUT_DIR/$COMPRESSED_IMAGE"; then
        log_message "Existing compressed image is valid. Skipping raw image creation and compression." "${GREEN}"
        COMPRESSION_SKIPPED=1
    else
        log_message "Removing incomplete compressed image and restarting compression." "${YELLOW}"
    fi
else
    log_message "No existing compressed image found." "${GREEN}"
fi

# Step 12: Create raw disk image (if needed)
if [[ -z "$RAW_IMAGE_EXISTS" && -z "$COMPRESSION_SKIPPED" ]]; then
    log_message "Step 12: Creating raw disk image from $DISK..." "${GREEN}"
    dd if="$DISK" of="$OUTPUT_DIR/$RAW_IMAGE" bs=4M status=progress || {
        log_message "Failed to create raw disk image." "${RED}"
        exit 1
    }
    log_message "Raw disk image created successfully." "${GREEN}"
else
    log_message "Step 12: Skipping raw image creation due to valid existing raw or compressed image." "${GREEN}"
fi

# Step 13: Compress the raw image (if needed)
if [[ -z "$COMPRESSION_SKIPPED" ]]; then
    log_message "Step 13: Compressing raw image to save space with progress bar..." "${GREEN}"
    nice -n 10 pv "$OUTPUT_DIR/$RAW_IMAGE" | gzip > "$OUTPUT_DIR/$COMPRESSED_IMAGE" || {
        log_message "Failed to compress image." "${RED}"
        exit 1
    }
    log_message "Raw image compressed successfully to $OUTPUT_DIR/$COMPRESSED_IMAGE." "${GREEN}"
else
    log_message "Step 13: Skipping compression due to valid existing compressed image." "${GREEN}"
fi

# Step 14: Create bootable ISO
log_message "Step 14: Creating bootable ISO image..." "${GREEN}"
genisoimage -o "$OUTPUT_DIR/$ISO_NAME" -b "$COMPRESSED_IMAGE" -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table "$OUTPUT_DIR/$COMPRESSED_IMAGE" || {
    log_message "Failed to create ISO image." "${RED}"
    exit 1
}
log_message "Bootable ISO image created successfully." "${GREEN}"

# Step 15: Verify ISO integrity
log_message "Step 15: Verifying ISO image..." "${GREEN}"
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

# Step 16: Clean up temporary files
log_message "Step 16: Cleaning up temporary files..." "${GREEN}"
rm -f "$OUTPUT_DIR/$COMPRESSED_IMAGE" || log_message "Warning: Failed to remove temporary file $COMPRESSED_IMAGE." "${YELLOW}"
log_message "Temporary files cleaned up." "${GREEN}"

# Step 17: Finalize
log_message "Step 17: Backup complete! ISO saved to $OUTPUT_DIR/$ISO_NAME" "${GREEN}"
log_message "Next steps:" "${YELLOW}"
log_message "1. Test the ISO in a virtual machine (e.g., VirtualBox, QEMU) to ensure it boots correctly." "${YELLOW}"
log_message "2. Store the ISO securely, preferably encrypted (e.g., 'gpg -c $ISO_NAME')." "${YELLOW}"
log_message "3. To restore, boot from the ISO and use 'dd' to write it back to a disk. Rebuild RAID1 using 'mdadm' if needed." "${YELLOW}"
log_message "4. Note: Restoring to a single disk will include RAID metadata. To restore RAID1, ensure both disks are configured with 'mdadm'." "${YELLOW}"

exit 0