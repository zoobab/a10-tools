#!/bin/bash
# Usage ./makeSD.sh /dev/sdx hwpack rootfs

now="`date +%Y%m%d-%H%M%S`"
logfile="a1x-media-create_$now.log"
exec 2>&1> >(tee -a $logfile)

hwpack_update_only=0

banner () {
echo "================================================================"
echo "$1"
echo "================================================================"
}


checkSyntax () {
	if [ -z $1 ] | [ -z $2 ] | [ -z $3 ]; then
		echo "Usage: $0 [device] [hwpack] [rootfs]"
                echo "Write norootfs for [rootfs] if you want to only update" 
                echo "u-boot, script.bin, the kernel and modules"
		exit 1
	fi

	if  [ ! -e $1 ]; then
		echo "Invalid device: $1"
		exit 1
	fi

	if  [ ! -f $2 ]; then
		echo "File $2 not found"
		exit 1
	fi
        if [ $3 != norootfs ]; then
	    if  [ ! -f $3 ]; then
		echo "File $3 not found"
		exit 1
	    fi
        else
            hwpack_update_only=1;
        fi
}

umountSD () {
	partlist=`mount | grep $1 | awk '{ print $1 }'`
	for part in $partlist
	do
		sudo umount $part
	done
}

partitionSD () {
    devicename=${1##/*/}
    subdevice=$1;
    if [ ${devicename:0:6} = "mmcblk" ]; then
        subdevice="${1}p"
    fi

    if [ ${devicename:0:4} = "loop" ]; then
        subdevice="${1}p"
    fi

	banner "Delete Existing Partition Table"
	sudo dd if=/dev/zero of=$1 bs=1M count=1

	banner "Creating Partitions"
	sudo parted $1 --script mklabel msdos
	if [ $? -ne 0 ]; then
		echo "Failed to create label for $1"
		exit 1
	fi 
	banner "Partition 1 - ${subdevice}1"
	sudo parted $1 --script mkpart primary fat32 2048s 16MB
	if [ $? -ne 0 ]; then
		echo "Failed to create ${subdevice}1 partition" 
		exit 1
	fi 
	vfat_end=` sudo fdisk -lu $1 | grep ${subdevice}1 | awk '{ print $3 }' `
	ext4_offset=`expr $vfat_end + 1`
	banner "Partition 2 (Starts at sector No. $ext4_offset)"
	sudo parted $1 --script mkpart primary ext4 ${ext4_offset}s -- -1
	if [ $? -ne 0 ]; then
		echo "Failed to create ${subdevice}2 partition"
		exit 1
	fi 
	banner "Format Partition 1 to VFAT"
	sudo mkfs.vfat -I ${subdevice}1
	if [ $? -ne 0 ]; then
		echo "Failed to format ${subdevice}1 partition"
		exit 1
	fi 
	banner "Format Partition 2 to EXT-4"
	sudo mkfs.ext4  ${subdevice}2
	if [ $? -ne 0 ]; then
		echo "Failed to format ${subdevice}2 partition"
		exit 1
	fi 
}

extractHWPack () {
    banner "Extracting HW Pack $1"
    mkdir -p hwpack
    pushd hwpack
    7z x ../$1
    popd
}

extractRootfs () {
    banner "extracting Rootfs $1"
    mkdir -p rootfs.tmp
    pushd rootfs.tmp
    fileext=`echo  $1  | sed 's/.*\.//'`
    banner "File Extension ${fileext}"
    if [ ${fileext} == "bz2" ]; then 
        sudo tar xjf ../$1
    elif [ ${fileext} == "gz" ]; then 
        sudo tar xzf ../$1
    elif [ ${fileext} == "7z" ] | [ ${fileext} == "lzma" ]; then 
        sudo 7z x ../$1
    elif [ ${fileext} == "xz" ]; then
        sudo tar xJf ../$1
    else
	echo "Unknown file extension: ${fileext}"
        popd
        exit 1
    fi
    popd
}

copyUbootSpl ()
{	
	banner "Copy U-Boot SPL to SD Card"
	sudo dd if=$2 bs=1024 of=$1 seek=8
}

copyUboot ()
{	
	banner "Copy U-Boot to SD Card"
	sudo dd if=$2 bs=1024 of=$1 seek=32
}

mountPartitions ()
{
    devicename=${1##/*/}
    subdevice=$1;
    if [ ${devicename:0:6} = "mmcblk" ]; then
        subdevice="${1}p"
    fi

    if [ ${devicename:0:4} = "loop" ]; then
        subdevice="${1}p"
    fi

	banner "Mount SD card partitions"
	mkdir -p mntSDvfat mntSDrootfs
	if [ $? -ne 0 ]; then
		echo "Failed to create SD card mount points"
		cleanup
	fi 
	banner "Mount VFAT Parition (SD)" 
	sudo mount ${subdevice}1 mntSDvfat
	if [ $? -ne 0 ]; then
		echo "Failed to mount VFAT partition (SD)"
		cleanup
	fi 
	banner "Mount EXT4 Parition (SD)" 
	sudo mount ${subdevice}2 mntSDrootfs
	if [ $? -ne 0 ]; then
		echo "Failed to mount EXT4 partition (SD)"
		cleanup
	fi 
}

umountPart() {
	if [ -d $1 ]; then
		mounted=`mount | grep $1`
		if [ ! -z mounted ]; then
			echo "Umount $2"
			sudo umount $1
			if [ $? -ne 0 ]; then
				echo "Failed to umount $2)"
			else
				echo "Delete $1"
				rm -rf $1
			fi
		else
			echo "Delete $1"
			rm -rf $1
		fi	 
	fi
}

copyData () 
{
	banner "Copy VFAT partition files to SD Card"
	sudo cp hwpack/kernel/uImage mntSDvfat
	if [ $? -ne 0 ]; then
		echo "Failed to copy VFAT partition data to SD Card"
		cleanup
	fi 
	sudo cp hwpack/kernel/*.bin mntSDvfat/script.bin
	if [ $? -ne 0 ]; then
		echo "Failed to copy VFAT partition data to SD Card"
		cleanup
	fi
	if [ -f hwpack/kernel/*.scr ]; then 
		sudo cp hwpack/kernel/*.scr mntSDvfat/boot.scr
		if [ $? -ne 0 ]; then
			echo "Failed to copy VFAT partition data to SD Card"
			cleanup
		fi
	fi
	 
        if [ ${hwpack_update_only} -eq 0 ]; then 
	    banner "Copy rootfs partition files to SD Card"
            if [ -d rootfs.tmp/etc ]; then
               echo "Standard rootfs"
	       sudo cp -a rootfs.tmp/* mntSDrootfs
            elif [ -d rootfs.tmp/binary/boot/filesystem.dir ]; then
               echo "Linaro rootfs"
	       sudo cp -a rootfs.tmp/binary/boot/filesystem.dir/* mntSDrootfs
            else
               echo "Unsupported rootfs"
               exit 1
            fi
        fi
	if [ $? -ne 0 ]; then
		echo "Failed to copy rootfs partition data to SD Card"
		cleanup
	fi 
        banner "Copy hwpack rootfs files"
	# Fedora uses a softlink for lib.  Adjust, if needed.
	if [ -L mntSDrootfs/lib ]; then
		# Find where it points.  For Fedora, we expect usr/lib.
		DEST=`/bin/ls -l mntSDrootfs/lib | sed -e 's,.* ,,'`
		if [ "$DEST" = "usr/lib" ]; then
			mv hwpack/rootfs/lib hwpack/rootfs/usr
		fi
	fi
        sudo cp -a hwpack/rootfs/* mntSDrootfs
	if [ $? -ne 0 ]; then
		echo "Failed to copy rootfs hwpack files to SD Card"
		cleanup
	fi 
}

cleanup ()
{
        if [ -d hwpack ]; then
            rm -rf hwpack
        fi
        if [ -d rootfs.tmp ]; then
            sudo rm -rf rootfs.tmp
        fi
	umountPart mntSDvfat "VFAT Partition (SD)"
	umountPart mntSDrootfs "EXT4 Partition (SD)"
	exit
}

# "main"
echo "a1x-media-create log file"
checkSyntax $1 $2 $3
umountSD $1
if [ ${hwpack_update_only} -eq 0 ]; then 
    partitionSD $1 
fi
extractHWPack $2
if [ ${hwpack_update_only} -eq 0 ]; then 
    extractRootfs $3
fi
copyUbootSpl $1 hwpack/bootloader/sunxi-spl.bin
copyUboot $1 hwpack/bootloader/u-boot.bin 
mountPartitions $1
copyData 
cleanup
