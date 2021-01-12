# !/bin/bash

# set -x
set -e

PWD=$(cd "$(dirname "$0")";pwd)
DEBUG_LEVEL=0
OUTDIR=output

MESG ()
{
	if [ $1 -le ${DEBUG_LEVEL} ]; then
		shift 1
		echo "$@"
	fi
}

INFO()
{
	MESG 0 INFO: $@
}

ERROR()
{
	MESG 0 ERROR: $@
}

WARING()
{
	MESG 0 WARING: $@
}

ERROR_EXIT()
{
	ERROR "$1"
	exit -1
}

usage()
{
	echo "usage: $0 <command> [ <option> ]"
	echo "command:"
	echo "	--chip					Set chip"
	echo "	--rk_sign_tool				Base secure boot"
	echo "		sl --loader <LOADER>"
	echo "		si --img <IMAGE>"
	echo "		all <PATH_TO_UBOOT>"
	echo "	--avb					AVB"
}

rk_sign_file()
{
	local PARAMETER
	local APPEND
	local SIGN_FLAG

	rm ${PWD}/tmp -rf
	mkdir ${PWD}/tmp

	while [ ! -z $1 ]
	do
		case $1 in
			--loader | --img)
				SIGN_FLAG=1
				;&
			--out|--key|--pubkey|--bin)
				PARAMETER="$PARAMETER"" $1"
				shift 1
				APPEND=$(cd "$(dirname "$1")";pwd)/$(basename "$1")
				cp $APPEND ${PWD}/tmp
				APPEND=${PWD}/tmp/$(basename "$1")
				PARAMETER="$PARAMETER"" $APPEND"
				;;
			*)
				PARAMETER="$PARAMETER"" $1"
				;;
		esac
		shift 1
	done

	cd $LINUX_SIGN_TOOL
	result=`./rk_sign_tool $PARAMETER`
	cd -

	if [ -z "$(echo $result | grep "sign image ok")" ] && [ -z "$(echo $result | grep "sign loader ok")" ] ; then
		ERROR_EXIT "Signed Faild!!!($PARAMETER)"
	fi

	INFO "sign file $FILE done"
	if [ "$SIGN_FLAG"x = "1"x ]; then
		INFO "move file $(ls ${PWD}/tmp) to ${OUTDIR}/rk_sign_tool"
		test -d ${OUTDIR}/rk_sign_tool || mkdir ${OUTDIR}/rk_sign_tool -p
		cp ${PWD}/tmp/* ${OUTDIR}/rk_sign_tool
		rm ${PWD}/tmp/* -rf
	fi
}

run_rk_sign_tool()
{
	# check parameter
	test -d "${LINUX_SIGN_TOOL}" || ERROR_EXIT "Not found LINUX_SIGN_TOOL(${LINUX_SIGN_TOOL}) directory"

	rk_sign_file $@
}

run_avb()
{
	# check parameter
	test -d "${LINUX_AVB_TOOL}" || ERROR_EXIT "Not found LINUX_AVB_TOOL(${LINUX_AVB_TOOL}) directory"

	${LINUX_AVB_TOOL}/avb_user_tool.sh $@
	test -d ${OUTDIR}/avb || mkdir ${OUTDIR}/avb -p

	cp ${LINUX_AVB_TOOL}/out/* ${OUTDIR}/avb

	echo TODO
}

source .setting.ini

while [ ! -z $1 ]
do
	case $1 in
		--debug)
			DEBUG_LEVEL=$2
			shift 2
			;;
		--chip)
			sed -i "s/^CHIP=.*/CHIP=$2/g" .setting.ini
			shift 2
			source .setting.ini # update
			;;
		--rk_sign_tool)
			rm ${LINUX_SIGN_TOOL}/setting.ini
			cp ${LINUX_SIGN_TOOL}/setting.ini.in ${LINUX_SIGN_TOOL}/setting.ini
			sed -i "s/\${CHIP}/${CHIP}/g" ${LINUX_SIGN_TOOL}/setting.ini
			sed -i "s:\${KEY}:${KEY}:g" ${LINUX_SIGN_TOOL}/setting.ini
			sed -i "s/\${EXCLUDE_BOOT}/${EXCLUDE_BOOT}/g" ${LINUX_SIGN_TOOL}/setting.ini

			shift 1
			if [ "$1"x == "all"x ]; then
				UBOOT_PATH=$2
				run_rk_sign_tool si --img ${UBOOT_PATH}/uboot.img
				run_rk_sign_tool si --img ${UBOOT_PATH}/trust.img
				LOADER=`ls $UBOOT_PATH/*_loader_*.bin`
				echo "LOADER=$LOADER"
				run_rk_sign_tool sl --loader $LOADER
			else
				run_rk_sign_tool $@
			fi
			exit $?
			;;
		--avb)
			shift 1
			run_avb $@
			exit $?
			;;
		*)
			usage $@
			exit 0
			;;
	esac
done

