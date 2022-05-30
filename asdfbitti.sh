#!/bin/bash

#=======
# CHECKS
#=======

# Check syntax

if [ $# -ne "1" ]; then
  echo "USAGE: asdfbitti.sh [image file]"
  exit
fi

SOURCE_IMG=$1

if [ ! -f "$SOURCE_IMG" ]; then
  echo "Given file ($SOURCE_IMG) does not exist."
  exit
fi

# Syntax OK

# Check if running as root

if [ "$EUID" -ne 0 ]
  then echo "asdfbitti.sh needs root permissions to mount and shit."
  exit
fi

# Root OK

# Check dependencies

echo "Checking dependencies..."

if which unsquashfs && which mksquashfs && which veritysetup && which awk && which sed && which rsync; then
  echo "Dependencies OK!"
else
  echo "Dependencies weren't met or they aren't in PATH."
  exit
fi

# Dependencies OK

#========
# PROGRAM
#========

#-----------
# Initialize
#-----------

# Get this file's location to locate fsroot
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Create temp directory for processing
TEMP_DIR=/tmp/asdfbitti
mkdir $TEMP_DIR

# Read partition offsets (fixed atm, can be made dynamic by using e.g. fdisk -l)
PART_1_OFFSET=1048576
PART_2_OFFSET=230686720

#------
# Patch
#------

# 2nd partition /////
mkdir $TEMP_DIR/mnt2
echo -n "Mounting partition 2..."
mount -o loop,offset=$PART_2_OFFSET $SOURCE_IMG $TEMP_DIR/mnt2
echo " OK!"

# Unsquash to temp
echo "Extracting squashfs... This may take a while."
unsquashfs -d $TEMP_DIR/fsroot $TEMP_DIR/mnt2/live/filesystem.squashfs
echo "Extraction complete."

# Perform edits
echo -n "Performing edits..."
source $SCRIPT_DIR/patch_commands

# Partially overwrite filesystem (still part of edits)
rsync -r $SCRIPT_DIR/fsroot/* $TEMP_DIR/fsroot/

echo " OK!"

# Resquash with xz
echo "Rebuilding squashfs... This will take several minutes."
mksquashfs $TEMP_DIR/fsroot/ $TEMP_DIR/filesystem.squashfs -comp xz
echo "Rebuilding complete."

# Delete old fs files from live and add new one(s?)
echo -n "Replacing the old filesystem..."
rm $TEMP_DIR/mnt2/live/filesystem.squashfs
rm $TEMP_DIR/mnt2/live/filesystem.hash
rm $TEMP_DIR/mnt2/live/filesystem.size
mv $TEMP_DIR/filesystem.squashfs $TEMP_DIR/mnt2/live
echo " OK!"

# Fs-size
echo -n "Creating size file..."
printf $(du -sx --block-size=1 $TEMP_DIR/mnt2/live/filesystem.squashfs | cut -f1) > $TEMP_DIR/mnt2/live/filesystem.size
echo " OK!"

# Verity format and save root hash
echo -n "Creating verity hashes..."
ROOT_HASH=$(veritysetup format $TEMP_DIR/mnt2/live/filesystem.squashfs $TEMP_DIR/mnt2/live/filesystem.hash | awk 'END {print $NF}')
echo " OK!"

# Get old root hash
echo -n "Reading old root hash..."
OLD_ROOT_HASH=$(grep -e "verityhash=[0-9a-f]\{64\}" $TEMP_DIR/mnt2/syslinux/digabi.c32 -a -o | tail -n 1 | cut -c 12-)
echo " OK!"

# Edit syslinux/digabi root hash to perfection
echo -n "Performing replace to legacy boot..."
sed -i s/$OLD_ROOT_HASH/$ROOT_HASH/g $TEMP_DIR/mnt2/syslinux/digabi.c32 
echo " OK!"

# Umount
echo -n "Unmounting partition 2..."
umount $TEMP_DIR/mnt2
echo " OK!"

# 1st partition /////
mkdir $TEMP_DIR/mnt1
echo -n "Mounting partition 1 (efi)..."
mount -o loop,offset=$PART_1_OFFSET $SOURCE_IMG $TEMP_DIR/mnt1
echo " OK!"

# Edit grub roothash
echo -n "Performing replace to UEFI boot..."
sed -i s/$OLD_ROOT_HASH/$ROOT_HASH/g $TEMP_DIR/mnt1/EFI/BOOT/grub64.efi 
sed -i s/$OLD_ROOT_HASH/$ROOT_HASH/g $TEMP_DIR/mnt1/EFI/BOOT/grub32.efi 
echo " OK!"

# Umount
echo -n "Unmounting partition 1 (efi)..."
umount $TEMP_DIR/mnt1
echo " OK!"

#--------
# Cleanup
#--------

rm -rf $TEMP_DIR

#=======
# REPORT
#=======

echo "asdfbitti.sh was successful!"
echo "$SOURCE_IMG is now patched."
