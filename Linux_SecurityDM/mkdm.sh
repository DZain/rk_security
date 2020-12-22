#!/bin/bash

force_copy_file()
{
	if [ ! -e $1 ]; then
		echo "Can't find $1"
		exit 1
	fi

	cp $1 $2
}

show_help()
{
	echo "$0 :"
	echo "	[c:d:s:k:r:m: ]"
	echo "	[debug,help,boot_only,ramdisk:,init:,key:,cipher:,outputfile:,filetype:,force_size:,inputfile:,inputimg:]"
	echo "	d:	set root patition in device"
	echo "	s:	set path to read-only system image"
	echo "	k:	set path to kernel Image"
	echo "	r:	set path to kernel resource.img"
	echo "	c:	set path to config file"
	echo "	m:	set mode (must be set)"
	echo "		subcmd:"
	echo "		dmv -- generate boot and rootfs.img with dmv info"
	echo "		fde -- generate encrypted.img/_info"
	echo "		fde-s -- generate encrypted.img/_info (system) and boot.img"
	echo "		ramdisk -- generate boot with ramdisk (do not chroot)"
	echo "	debug:		print debug msg"
	echo "	help:		print help"
	echo "	boot_only:	update boot.img only"
	echo "	ramdisk:	set path to ramdisk"
	echo "	init:		chroot init script"
	echo "	key:		used to dmsetup"
	echo "	cipher:		used to dmsetup"
	echo "	outputfile:	fde mode output file (OUTPUT/encrypted.img as default)"
	echo "	inputfile:	used to encrypt"
	echo "	inputimg:	used img file instead of inputfile"
	echo "	filetype:	used to formate encrypt partition (ext4 as default)"
	echo "	force_size:	force alloc spec space for encrypted partition"
	echo "======================================"
	echo "	DM-V only support read-only system verity"
	echo "	Mode fde(-s): encrypted.img unabled to compression"
}

print_err()
{
	echo $1
	exit 1;
}

pr_run()
{
	test ! -z $DEBUG && echo $1
	rc=`echo ${1}|awk '{run=$0;rc=system(run);print rc}'`
	[ "$rc" != "0" ] && print_err $rc
}

check_parameter_boot()
{
	test -z $ROOT_DEV && print_err "No ROOT_DEV, please set it with -d or in config file"
	test -z $KERNEL_PATH && print_err "No KERNEL_PATH, please set it with -k or in config file"
	test -z $RESOURCE_PATH && print_err "No RESOURCE_PATH, please set it with -r or in config file"
}

check_parameter_dmv()
{
	check_parameter_boot
	test -z $ROOTFS_PATH && print_err "No ROOTFS_PATH, please set it with -s or in config file"
}

check_parameter_fde()
{
	if [ -z $inputfile ]; then
		test -z $inputimg && print_err "No input file"
		test ! -e $inputimg && print_err "Can't Found $inputimg"
		mkdir ${OUTPUT}/tempfile/mount -p
		sudo umount ${OUTPUT}/tempfile/mount > /dev/null 2>&1
		pr_run "sudo mount $inputimg ${OUTPUT}/tempfile/mount"
		inputfile=${OUTPUT}/tempfile/mount
	fi

	test -z $key && print_err "No key match to $cipher"
}

check_parameter()
{
	test -z $MODE && print_err "MODE(-m) must be set"
	case "$MODE" in
		dmv) check_parameter_dmv ;;
		fde) check_parameter_fde ;;
		fde-s) check_parameter_boot ; check_parameter_fde ;;
		ramdisk) ;;
	esac
}

print_parameter()
{
	echo MODE: $MODE
	echo ROOT_DEV: $ROOT_DEV
	echo INIT: $INIT
	echo ROOTFS_PATH: $ROOTFS_PATH
	echo KERNEL_PATH: $KERNEL_PATH
	echo RESOURCE_PATH: $RESOURCE_PATH
	echo RAMDISK_PATH: $RAMDISK_PATH
	echo BOOT_ONLY: $BOOT_ONLY

	echo cipher $cipher
	echo key $key
	echo filetype $filetype
	echo outputfile $outputfile
	echo inputfile $inputfile
}

mk_ramdisk_boot()
{
	pr_run "cd ${RAMDISK_DIR} && find . | cpio -o -H newc | gzip -9 -c > /tmp/boot.cpio.gz && cd - && ./mkbootimg --kernel ${KERNEL_PATH} --second ${RESOURCE_PATH} --ramdisk /tmp/boot.cpio.gz --output ${OUTPUT}/boot.img && cd -"
	echo "Generated ${OUTPUT}/boot.img"
}

fix_ramdisk_dm_v()
{
	ROOTFS=${OUTPUT}/rootfs_dmv.img
	ROOT_HASH=${TEMPDIR}/root.hash
	ROOT_HASH_OFFSET=${TEMPDIR}/root.offset

	if [ -z $BOOT_ONLY ]; then
		force_copy_file ${ROOTFS_PATH} ${ROOTFS}
		ROOTFS_SIZE=`ls ${ROOTFS} -l | awk '{printf $5}'`
		# at least 1M greater
		HASH_OFFSET=$[(ROOTFS_SIZE / 1024 / 1024 + 2) * 1024 * 1024]
		tempfile=`mktemp /tmp/temp.XXXXXX`
		pr_run "sudo veritysetup --hash-offset=${HASH_OFFSET} format ${ROOTFS} ${ROOTFS} > ${tempfile}"
		cat ${tempfile} | grep "Root hash" | awk '{printf $3}' > ${ROOT_HASH}
		rm ${tempfile}
		echo $HASH_OFFSET > ${ROOT_HASH_OFFSET}
	else
		test ! -e $ROOT_HASH && print_err "No ROOT_HASH, generate it first"
		test ! -e $ROOT_HASH_OFFSET && print_err "No ROOT_HASH_OFFSET, generate it first"
	fi

	echo "Generated ${ROOTFS}"
	cp ${RAMDISK_DIR}/init_dmv_sample ${RAMDISK_DIR}/init
	TMP=`cat ${ROOT_HASH}`
	sed -i "s#ROOT_HASH#${TMP}#g" ${RAMDISK_DIR}/init
	TMP=`cat ${ROOT_HASH_OFFSET}`
	sed -i "s#HASH_OFFSET#${TMP}#g" ${RAMDISK_DIR}/init
	sed -i "s#ROOT_DEV#${ROOT_DEV}#g" ${RAMDISK_DIR}/init
	sed -i "s#INIT#${INIT}#g" ${RAMDISK_DIR}/init
}

attach_encrypted_container()
{
	pr_run "sudo losetup ${loopdevice} ${outputfile}"
	pr_run "sudo dmsetup create $mappername --table \"0 $sectors crypt $cipher $key 0 $loopdevice 0 1 allow_discards\""
}

fix_ramdisk_dm_c()
{
	if [ $MODE == "fde-s" ]; then
		test ! -e ${OUTPUT}/encrypted_info && print_err "No encrypted info, generated encrypted system first"
		source ${OUTPUT}/encrypted_info
		cp ${RAMDISK_DIR}/init_dm_sample ${RAMDISK_DIR}/init
		sed -i "s#ROOT_DEV#${ROOT_DEV}#g" ${RAMDISK_DIR}/init
		sed -i "s#SECTORS#${sectors}#g" ${RAMDISK_DIR}/init
		sed -i "s#CIPHER#${cipher}#g" ${RAMDISK_DIR}/init
		sed -i "s#KEY#${key}#g" ${RAMDISK_DIR}/init
		mk_ramdisk_boot
	fi
}

encrypt_file()
{
	test ! -z $BOOT_ONLY && return
	if [ -z $force_size ]; then
		sectors=`sudo du -sh $inputfile | awk '{printf $1}' | tr -cd "[0-9]"`
		sectors=$[(sectors + 20) * 2 * 1024] # remain 20M for partition info
	else
		sectors=$[sectors * 2 * 1024]
	fi

	loopdevice=`losetup -f`
	mappername=encfs-$(shuf -i 1-10000000000000000000 -n 1)
	mountpoint=$(mktemp -d)

	test -e ${outputfile} && rm ${outputfile} -f
	pr_run "sudo dd if=/dev/null of=${outputfile} seek=${sectors} bs=512"
	#pr_run "sudo dd if=/dev/zero of=${outputfile} count=${sectors} bs=512"

	echo maapername ${mappername}
	echo loopdevice $loopdevice
	echo mountpoint $mountpoint
	attach_encrypted_container
	sudo mkfs.$filetype /dev/mapper/$mappername
	pr_run "sudo mount /dev/mapper/$mappername $mountpoint"
	pr_run "sudo cp -Rp $inputfile/* $mountpoint"
	test ! -z $inputimg && pr_run "sudo umount ${OUTPUT}/tempfile/mount"
	pr_run "sudo umount $mountpoint"
	pr_run "sudo rm -rf $mountpoint"
	pr_run "sudo dmsetup remove $mappername"
	pr_run "sudo losetup -d $loopdevice"
	echo "Generated $outputfile"

	echo "#dmsetup create $mappername --table \"0 $sectors crypt $cipher $key 0 TARGET_PARTITION 0 1 allow_discards\"" > ${OUTPUT}/encrypted_info
	echo "sectors=$sectors" >> ${OUTPUT}/encrypted_info
	echo "cipher=$cipher" >> ${OUTPUT}/encrypted_info
	echo "key=$key" >> ${OUTPUT}/encrypted_info
	echo "Generated ${OUTPUT}/encrypted_info"
}

getparameter()
{
	if [ -e $1 ]; then
		source $1
	else
		echo "No fount $1"
	fi
}

PWD=$(cd `dirname $0`; pwd)
OUTPUT=${PWD}/output
RAMDISK_PATH=${PWD}/ramdisk
if [ ! -d $RAMDISK_PATH ]; then
	cd $PWD
	tar -xzvf ramdisk.tar.gz -o ramdisk
	cd -
fi

TEMPDIR=${OUTPUT}/tempfile
RAMDISK_DIR=${TEMPDIR}/ramdisk
INIT=/init
cipher=aes-cbc-plain
#key=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
filetype=ext4
outputfile=${OUTPUT}/encrypted.img

parameter=`getopt -o c:d:s:k:r:m: -l debug,help,boot_only,ramdisk:,init:,key:,cipher:,outputfile:,filetype:,force_size:,inputfile:,inputimg: -n "$0" -- "$@"`
if [ $? != 0 ]; then
	echo "Terminating ......" >&2
	exit 1
fi

eval set -- "$parameter"

while true
do
	case "$1" in
		-d)		ROOT_DEV="$2" ; shift 2 ;;
		-s)		ROOTFS_PATH="$2" ; shift 2 ;;
		-k)		KERNEL_PATH="$2" ; shift 2 ;;
		-r)		RESOURCE_PATH="$2" ; shift 2 ;;
		-c)		getparameter $2 ; shift 2 ;; #CONFIG="$2" ; shift 2 ;;
		-m)		MODE="$2" ; shift 2 ;;
		--inputfile)	inputfile=$2; shift 2;;
		--inputimg)	inputimg=$2; shift 2;;
		--init)		INIT="$2" ; shift 2 ;;
		--debug)	DEBUG=1 ; shift ;;
		--help)		show_help ; shift ; exit 0 ;;
		--boot_only)	BOOT_ONLY=1 ; shift ;;
		--ramdisk)	RAMDISK_PATH="$2" ; shift 2 ;;
		--key)		key=$2 ; shift 2 ;;
		--filetype)	filetype=$2 ; shift 2 ;;
		--outputfile)	outputfile=${OUTPUT}/$2 ; shift 2 ;;
		--force_size)	sectors=$2; shift 2 ;; #M
		--cipher)	cipher=$2; shift 2 ;;
		--)		shift ; break ;;
		*)		echo "Internal error!" ; exit 1 ;;
	esac
done

#=====================USER CONFIG
#test ! -z $CONFIG && source $CONFIG
check_parameter
test ! -z $DEBUG && print_parameter

if [ $MODE != "fde" ]; then
	test -e ${RAMDISK_DIR} && rm ${RAMDISK_DIR} -r
	test ! -e ${OUTPUT} && mkdir ${OUTPUT} -p
	test ! -e ${TEMPDIR} && mkdir ${TEMPDIR} -p
	cp ${RAMDISK_PATH} ${RAMDISK_DIR} -r
fi

case "$MODE" in
	dmv) fix_ramdisk_dm_v ;&
	ramdisk) mk_ramdisk_boot ;;
	fde | fde-s) encrypt_file; fix_ramdisk_dm_c ;;
esac

