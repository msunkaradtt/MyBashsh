#!/bin/bash

# Script to create a bootable ISO image of a Linux server with RAID1, backing up only used data

# Exit on any error
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration (adjust these as needed)
DISK="/dev/sda" # Disk to verify RAID1 (not directly backed up)
MD_DEVICES=("/dev/md0" "/dev/md1" "/dev/md2") # RAID1 devices (swap, /boot, /)
OUTPUT_DIR="/mnt/localdisk" # Directory to store the ISO (must not be on /dev/sda or /dev/sdb)
ISO_NAME="server_backup_$(date +%Y%m%d_%H%M%S).iso"
BACKUP_DIR="backup_$(date +%Y%m%d_%H%M%S)"
COMPRESSED_IMAGE="backup.tar.gz"
MIN_SPACE_GB=10 # Minimum free space required in GB
MOUNT_CHECK="/proc/mounts"
MAX_ISO_FILE_SIZE=$((4 * 1024 * 1024 * 1024)) # 4GiB limit for ISO files
SSHFS_RETRIES=3 # Number of retries for SSHFS mount

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

# Function to check if file is in use
check_file_in_use() {
    local file="$1"
    if command -v lsof >/dev/null; then
        if lsof "$file" >/dev/null 2>&1; then
            log_message "Error: File $file is in use by another process. Exiting." "${RED}"
            exit 1
        fi
    else
        log_message "Warning: lsof not installed. Cannot check if $file is in use. Proceeding with caution." "${YELLOW}"
    fi
}

# Function to check SSHFS mount integrity with retries
check_sshfs_mount() {
    local mount_point="$1"
    local retries=$2
    local attempt=1
    while [[ $attempt -le $retries ]]; do
        if mountpoint -q "$mount_point"; then
            # Test write to ensure mount is functional
            local test_file="$mount_point/.test_$(date +%s)"
            if touch "$test_file" 2>/dev/null; then
                rm -f "$test_file"
                log_message "$mount_point is mounted and writable." "${GREEN}"
                return 0
            else
                log_message "Attempt $attempt/$retries: Cannot write to $mount_point. SSHFS mount may be broken." "${YELLOW}"
            fi
        else
            log_message "Attempt $attempt/$retries: $mount_point is not a valid mount point." "${YELLOW}"
        fi
        if [[ $attempt -lt $retries ]]; then
            log_message "Retrying SSHFS mount..." "${YELLOW}"
            umount "$mount_point" 2>/dev/null || true
            sshfs msunkaradtt@localhost:/mnt/f/backup "$mount_point" -p 2222 -o allow_other,ServerAliveInterval=60,ServerAliveCountMax=3 || {
                log_message "Failed to remount $mount_point." "${RED}"
            }
            sleep 5
        fi
        ((attempt++))
    done
    log_message "Error: Failed to verify $mount_point after $retries attempts. Exiting." "${RED}"
    exit 1
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
for tool in partclone.ext4 partclone.swap tar genisoimage gzip mdadm pv lsof mountpoint; do
    if ! command -v $tool &>/dev/null; then
        log_message "$tool is not installed. Please install it (e.g., 'apt install partclone tar genisoimage gzip mdadm pv lsof util-linux')." "${RED}"
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
    log_message "RAID not detected. Is this a RAID system?" "${RED}"
    exit 1
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

# Step 5: Check SSHFS mount integrity
log_message "Step 5: Verifying SSHFS mount $OUTPUT_DIR..." "${GREEN}"
check_sshfs_mount "$OUTPUT_DIR" "$SSHFS_RETRIES"
log_message "SSHFS mount verified." "${GREEN}"

# Step 6: Check if output directory is on the disk being backed up
log_message "Step 6: Ensuring output directory is not on $DISK or /dev/sdb..." "${GREEN}"
if df "$OUTPUT_DIR" | grep -qE "/dev/sda|/dev/sdb"; then
    log_message "Error: Output directory $OUTPUT_DIR is on $DISK or /dev/sdb. Choose a different disk (e.g., external drive)." "${RED}"
    exit 1
fi
log_message "Output directory is on a separate disk." "${GREEN}"

# Step 7: Check if RAID devices exist
log_message "Step 7: Verifying RAID devices exist..." "${GREEN}"
for md in "${MD_DEVICES[@]}"; do
    if [[ ! -b "$md" ]]; then
        log_message "RAID device $md does not exist. Exiting." "${RED}"
        exit 1
    fi
done
log_message "All RAID devices confirmed." "${GREEN}"

# Step 8: Check if RAID devices are mounted
log_message "Step 8: Checking if RAID devices are mounted..." "${GREEN}"
for md in "${MD_DEVICES[@]}"; do
    if grep -qs "$md" "$MOUNT_CHECK"; then
        log_message "Warning: $md is mounted. This may cause data corruption in the backup." "${YELLOW}"
        log_message "For a cleaner backup, boot from a live CD/USB (e.g., SystemRescueCD) or stop services and unmount partitions." "${YELLOW}"
        read -p "Continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_message "Aborting at user request." "${RED}"
            exit 1
        fi
    fi
done
log_message "RAID device mount check complete." "${GREEN}"

# Step 9: Check for running services
log_message "Step 9: Checking for active services..." "${GREEN}"
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

# Step 10: Check available space in output directory
log_message "Step 10: Checking available space in $OUTPUT_DIR..." "${GREEN}"
# Estimate required space based on used space in filesystems
USED_SPACE=0
for md in "${MD_DEVICES[@]}"; do
    if [[ "$md" == "/dev/md0" ]]; then
        # Swap: Estimate small size for metadata
        USED_SPACE=$((USED_SPACE + 1)) # Assume 1GB for swap
    else
        # Get used space for ext4 filesystems
        USED_SPACE=$((USED_SPACE + $(df -B1G "$md" | tail -n 1 | awk '{print $3}' 2>/dev/null || echo 0)))
    fi
done
REQUIRED_SPACE_GB=$((USED_SPACE + MIN_SPACE_GB))
AVAILABLE_SPACE=$(df -B1G "$OUTPUT_DIR" | tail -n 1 | awk '{print $4}')
if [[ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE_GB" ]]; then
    log_message "Insufficient space in $OUTPUT_DIR. Need ${REQUIRED_SPACE_GB}GB, but only ${AVAILABLE_SPACE}GB available." "${RED}"
    exit 1
fi
log_message "Sufficient space available: ${AVAILABLE_SPACE}GB in $OUTPUT_DIR for estimated ${REQUIRED_SPACE_GB}GB." "${GREEN}"

# Step 11: Create backup directory
log_message "Step 11: Creating backup directory $OUTPUT_DIR/$BACKUP_DIR..." "${GREEN}"
check_sshfs_mount "$OUTPUT_DIR" "$SSHFS_RETRIES"
mkdir -p "$OUTPUT_DIR/$BACKUP_DIR" || {
    log_message "Failed to create $OUTPUT_DIR/$BACKUP_DIR. Exiting." "${RED}"
    exit 1
}
log_message "Backup directory created." "${GREEN}"

# Step 12: Backup RAID metadata
log_message "Step 12: Backing up RAID metadata..." "${GREEN}"
check_sshfs_mount "$OUTPUT_DIR" "$SSHFS_RETRIES"
mdadm --detail --scan > "$OUTPUT_DIR/$BACKUP_DIR/mdadm.conf" || {
    log_message "Failed to save RAID metadata." "${RED}"
    exit 1
}
log_message "RAID metadata saved to $OUTPUT_DIR/$BACKUP_DIR/mdadm.conf." "${GREEN}"

# Step 13: Backup filesystems with partclone
log_message "Step 13: Backing up filesystems with partclone..." "${GREEN}"
check_sshfs_mount "$OUTPUT_DIR" "$SSHFS_RETRIES"
for md in "${MD_DEVICES[@]}"; do
    log_message "Processing $md..." "${GREEN}"
    if [[ "$md" == "/dev/md0" ]]; then
        # Backup swap
        partclone.swap -c -s "$md" -o "$OUTPUT_DIR/$BACKUP_DIR/$(basename $md).img" | pv -s 1G || {
            log_message "Failed to backup swap $md." "${RED}"
            exit 1
        }
    else
        # Backup ext4 filesystem
        partclone.ext4 -c -s "$md" -o "$OUTPUT_DIR/$BACKUP_DIR/$(basename $md).img" | pv || {
            log_message "Failed to backup filesystem $md." "${RED}"
            exit 1
        }
    fi
    log_message "Backup of $md completed." "${GREEN}"
done
log_message "All filesystems backed up." "${GREEN}"

# Step 14: Compress backup directory
log_message "Step 14: Compressing backup directory to $OUTPUT_DIR/$COMPRESSED_IMAGE..." "${GREEN}"
check_sshfs_mount "$OUTPUT_DIR" "$SSHFS_RETRIES"
check_file_in_use "$OUTPUT_DIR/$BACKUP_DIR"
nice -n 10 tar -C "$OUTPUT_DIR" -czf "$OUTPUT_DIR/$COMPRESSED_IMAGE" "$BACKUP_DIR" | pv || {
    log_message "Failed to compress backup directory." "${RED}"
    exit 1
}
log_message "Backup directory compressed successfully." "${GREEN}"

# Step 15: Verify compressed image
log_message "Step 15: Verifying compressed image $OUTPUT_DIR/$COMPRESSED_IMAGE..." "${GREEN}"
check_sshfs_mount "$OUTPUT_DIR" "$SSHFS_RETRIES"
if check_gzip_integrity "$OUTPUT_DIR/$COMPRESSED_IMAGE"; then
    COMPRESSED_SIZE=$(stat -c %s "$OUTPUT_DIR/$COMPRESSED_IMAGE")
    if [[ "$COMPRESSED_SIZE" -gt "$MAX_ISO_FILE_SIZE" ]]; then
        log_message "Warning: Compressed image ($COMPRESSED_SIZE bytes) exceeds 4GiB. Creating UDF-based ISO." "${YELLOW}"
    fi
else
    log_message "Compressed image verification failed. Exiting." "${RED}"
    exit 1
fi
log_message "Compressed image verified." "${GREEN}"

# Step 16: Create bootable ISO
log_message "Step 16: Creating bootable UDF ISO image..." "${GREEN}"
check_sshfs_mount "$OUTPUT_DIR" "$SSHFS_RETRIES"
check_file_in_use "$OUTPUT_DIR/$COMPRESSED_IMAGE"
genisoimage -o "$OUTPUT_DIR/$ISO_NAME" -udf -b "$COMPRESSED_IMAGE" -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -allow-limited-size "$OUTPUT_DIR/$COMPRESSED_IMAGE" || {
    log_message "Failed to create ISO image." "${RED}"
    exit 1
}
log_message "Bootable ISO image created successfully." "${GREEN}"

# Step 17: Verify ISO integrity
log_message "Step 17: Verifying ISO image..." "${GREEN}"
check_sshfs_mount "$OUTPUT_DIR" "$SSHFS_RETRIES"
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

# Step 18: Clean up temporary files
log_message "Step 18: Cleaning up temporary files..." "${GREEN}"
rm -rf "$OUTPUT_DIR/$BACKUP_DIR" "$OUTPUT_DIR/$COMPRESSED_IMAGE" || log_message "Warning: Failed to remove temporary file(s)." "${YELLOW}"
log_message "Temporary files cleaned up." "${GREEN}"

# Step 19: Finalize
log_message "Step 19: Backup complete! ISO saved to $OUTPUT_DIR/$ISO_NAME" "${GREEN}"
log_message "Next steps:" "${YELLOW}"
log_message "1. Test the ISO in a virtual machine (e.g., VirtualBox, QEMU) to ensure it boots correctly." "${YELLOW}"
log_message "2. Store the ISO securely, preferably encrypted (e.g., 'gpg -c $ISO_NAME')." "${YELLOW}"
log_message "3. To restore, boot from a live CD/USB (e.g., SystemRescueCD), extract the tar.gz, restore filesystems with 'partclone', and rebuild RAID1 with 'mdadm'." "${YELLOW}"
log_message "4. Example restoration commands:" "${YELLOW}"
log_message "   - Extract: tar -xzf /path/to/backup.tar.gz" "${YELLOW}"
log_message "   - Restore swap: partclone.swap -r -s backup/md0.img -o /dev/md0" "${YELLOW}"
log_message "   - Restore ext4: partclone.ext4 -r -s backup/md1.img -o /dev/md1" "${YELLOW}"
log_message "   - Rebuild RAID: mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sda1 /dev/sdb1" "${YELLOW}"

exit 0