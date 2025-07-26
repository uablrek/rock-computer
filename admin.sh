#! /bin/sh
##
## rock.sh --
##
##   Script for managing Radxa ROCK computers
##
## Commands;
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
me=$dir/$prg
test -n "$TEMP" || TEMP=/tmp/tmp/$USER
tmp=$TEMP/${prg}_$$

die() {
    echo "ERROR: $*" >&2
    rm -rf $tmp
    exit 1
}
help() {
    grep '^##' $0 | cut -c3-
    rm -rf $tmp
    exit 0
}
test -n "$1" || help
echo "$1" | grep -qi "^help\|-h" && help

log() {
	echo "$*" >&2
}
findf() {
	local d
	for d in $(echo $FSEARCH_PATH | tr : ' '); do
		f=$d/$1
		test -r $f && return 0
	done
	unset f
	return 1
}
findar() {
	findf $1.tar.bz2 || findf $1.tar.gz || findf $1.tar.xz || findf $1.zip
}


##   env
##     Print environment.
cmd_env() {
	test "$envread" = "yes" && return 0
	envread=yes
    versions
    unset opts

	eset ARCHIVE=$HOME/archive
	eset FSEARCH_PATH=$HOME/Downloads:$ARCHIVE
	eset \
		ROCK_WORKSPACE=$TEMP/ROCK \
		KERNELDIR=$HOME/tmp/linux
	eset WS=$ROCK_WORKSPACE
	eset __kobj=$WS/obj/$ver_kernel
	eset __board=rock-4se-rk3399
	eset \
		__kcfg=$dir/config/$ver_kernel \
		__kdir=$KERNELDIR/$ver_kernel \
		kernel=$__kobj/arch/arm64/boot/Image \
		dtb=$__kobj/arch/arm64/boot/dts/rockchip/rk3399-rock-4se.dtb \
		__tftproot=$WS/tftproot \
		__httproot=$WS/httproot \
		__bbcfg=$dir/config/$ver_busybox \
		__initrd=$__kobj/initrd.cpio.gz \
		__ubootcfg=$dir/config/uboot-$__board.config \
		__ubootobj=$WS/uboot-$__board-obj \
		__sdimage=$WS/sd-$__board.img \
		__bootscr=$dir/config/u-boot.scr \
		__busybox=$WS/local/$ver_busybox/busybox \
		KCFG_BACKUP=''
	eset BL31=$WS/$ver_trust/build/rk3399/release/bl31/bl31.elf		
	if test "$cmd" = "env"; then
		set | grep -E "^($opts)="
		exit 0
	fi
	test -n "$long_opts" && export $long_opts

	__arch=aarch64
	mkdir -p $WS || die "Can't mkdir [$WS]"
	disk=$dir/disk.sh
	cd $dir
}
# Set variables unless already defined. Vars are collected into $opts
eset() {
	local e k
	for e in $@; do
		k=$(echo $e | cut -d= -f1)
		opts="$opts|$k"
		test -n "$(eval echo \$$k)" || eval $e
	done
}
check_local_addr() {
	test -n "$__local_addr" || die "No --local_addr"
	if ! echo $__local_addr | grep -q -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/24'; then
		log "Invalid local_addr [$__local_addr]"
		die "MUST be an IPv4 address with /24, e.g 10.0.0.1/24"
	fi
}
##   versions [--brief]
##     Print used sw versions
versions() {
	eset \
		ver_kernel=linux-6.15.8 \
		ver_busybox=busybox-1.36.1 \
		ver_atftp=atftp-0.8.0 \
		ver_uboot=u-boot-2025.07 \
		ver_trust=trusted-firmware-a-lts-v2.12.4
}
cmd_versions() {
	unset opts
	versions
	if test "$__brief" = "yes"; then
	   set | grep -E "^($opts)="
	   return 0
	fi
	local k v
	for k in $(echo $opts | tr '|' ' '); do
		v=$(eval echo \$$k)
		if findar $v; then
			printf "%-20s (%s)\n" $v $f
		else
			printf "%-20s (archive missing!)\n" $v
		fi
	done
}
# cdsrc <version>
# Cd to the source directory. Unpack the archive if necessary.
cdsrc() {
	test -n "$1" || die "cdsrc: no version"
	test "$__clean" = "yes" && rm -rf $WS/$1
	if ! test -d $WS/$1; then
		findar $1 || die "No archive for [$1]"
		if echo $f | grep -qF '.zip'; then
			unzip -d $WS -qq $f || die "Unzip [$f]"
		else
			tar -C $WS -xf $f || die "Unpack [$f]"
		fi
	fi
	cd $WS/$1
}
##   setup --dev=<UNUSED-wired-interface> [--clean]
##     Setup from scratch. The kernel and BusyBox are built, and an
##     initrd created. The local interface, dhcpd and tftpd are setup.
##     WARNING: Requires "sudo"
cmd_setup() {
	test -n "$__dev" || die "No --dev"
	check_local_addr
	if test "$__clean" = "yes"; then
		rm -rf $WS
		# We must restart dhcpd and tftpd since their config dirs were removed!
		export __restart=yes
	fi
	$me interface_setup || die interface_setup
	$me dhcpd || die dhcpd
	$me atftp_build || die atftp_build
	$me tftpd || die tftpd
	$me trustedf_build || die trustedf_build
	$me uboot_build || die uboot_build
	$me busybox_build || die busybox_build
	$me kernel_build || die kernel_build
	$me initrd_build || die initrd_build
	$me tftp_setup || die tftp_setup
}
##   interface_setup --dev=<UNUSED-wired-interface> --local-addr=ipv4/24
##     Setup the local wired interface. An IPv4 /24 address must be used.
##     Iptables masquerading setup, and forward accepted.
##     WARNING: this requires "sudo" and may disable your network
##        if --dev is used for something
cmd_interface_setup() {
	test -n "$__dev" || die "No unused wired interface specified"
	if ip -4 addr show dev $__dev | grep -q inet; then
		log "IPv4 address already exist on [$__dev]"
		return 0
	fi
	check_local_addr
	ip link show $__dev > /dev/null || die "Not found [$__dev]"
	echo $__local_addr | grep -q '/24$' || \
		die "Not a IPv4 /24 address [$__local_addr]"
	sudo ip link set up $__dev || die "ip link set up"
	sudo ip addr add $__local_addr dev $__dev || die "addr add"
	local cidr=$(echo $__local_addr | sed -E 's,[0-9]+/24,0/24,')
	sudo iptables -t nat -A POSTROUTING -s $cidr -j MASQUERADE
	sudo iptables -A FORWARD -s $cidr -j ACCEPT
	sudo iptables -A FORWARD -d $cidr -j ACCEPT
}
##   trustedf_build [--clean]
##     Build TrustedFirmware-A/trusted-firmware-a. This is used
##     by u-boot and set in the $BL31 environment variable.
cmd_trustedf_build() {
	if test -r $BL31; then
		log "Already built [$BL31]"
		return 0
	fi
	which arm-none-eabi-gcc > /dev/null || \
		die "Not installed [gcc-arm-none-eabi]"
	cdsrc $ver_trust
	make -j$(nproc) CROSS_COMPILE=aarch64-linux-gnu- PLAT=rk3399
}
##   uboot_build [--default] [--board=] [--menuconfig]
##     Build U-boot for rock-4se-rk3399. --default re-initiates the config.
cmd_uboot_build() {
	cdsrc $ver_uboot
	export CROSS_COMPILE=aarch64-linux-gnu-
	which ${CROSS_COMPILE}gcc > /dev/null || die "No aarch64 cross-compiler"
	test -r $BL31 || die "Not readable [$BL31]"
	export BL31
	export ARCH=arm64
	test "$__clean" = "yes" && rm -rf $__ubootobj
	mkdir -p $__ubootobj
	
	local make="make O=$__ubootobj -j$(nproc)"
	if test "$__default" = "yes"; then
		$make ${__board}_defconfig || die "make default"
		cp $__ubootobj/.config $__ubootcfg || die "Store U-boot config"
		__menuconfig=yes
	fi
	test -r "$__ubootcfg" || die "Not readable [$__ubootcfg]"
	cp "$__ubootcfg" $__ubootobj/.config
	if test "$__menuconfig" = "yes"; then
		$make menuconfig || die "make menuconfig"
		cp $__ubootobj/.config $__ubootcfg || die "Store U-boot config"
	fi
	$make || die make
	$make u-boot.itb || die "make u-boot.itb"
	cd $__ubootobj
	if ! test -r idbloader.img; then
	   log "Creating idbloader.img using tools/mkimage..."
	   tools/mkimage -n rk3399 -T rksd -d tpl/u-boot-tpl.bin idbloader.img \
		   || die "mkimage idbloader.img"
	fi
}
#   kernel_unpack
#     Unpack the kernel at $KERNELDIR
cmd_kernel_unpack() {
	test -d $__kdir && return 0	  # (already unpacked)
	log "Unpack kernel to [$__kdir]..."
	findar $ver_kernel || die "Kernel source not found [$ver_kernel]"
	mkdir -p $KERNELDIR
	tar -C $KERNELDIR -xf $f
}
##   kernel_build --initconfig=     # Init the kcfg
##   kernel_build --restoreconfig=  # restore config from backup
##   kernel_build [--clean] [--menuconfig]
##     Build the kernel.
cmd_kernel_build() {
	cmd_kernel_unpack
	test "$__clean" = "yes" && rm -rf $__kobj
	mkdir -p $__kobj

	local CROSS_COMPILE=aarch64-linux-gnu-
	local make="make -C $__kdir O=$__kobj ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE"
	if test -n "$__initconfig"; then
		rm -r $__kobj
		mkdir -p $__kobj $(dirname $__kcfg)
		$make -C $__kdir O=$__kobj $__initconfig || die "make $__initconfig"
		cp $__kobj/.config $__kcfg
		__menuconfig=yes
	elif test -n "$__restoreconfig"; then
		test -n "$KCFG_BACKUP" || die 'Not set [$KCFG_BACKUP]'
		local c=$KCFG_BACKUP/$__restoreconfig
		test -r $c || die "Not readable [$c]"
		cp $c $__kcfg
	fi

	test -r $__kcfg || die "Not readable [$__kcfg]"
	cp $__kcfg $__kobj/.config
	if test "$__menuconfig" = "yes"; then
		if test -n "$KCFG_BACKUP"; then
			mkdir -p $KCFG_BACKUP || die "mkdir $KCFG_BACKUP"
			local c=$(basename $__kcfg)
			cp $__kcfg $KCFG_BACKUP/$c-$(date +'%F-%H.%M')
		fi
		$make menuconfig
		cp $__kobj/.config $__kcfg
	else
		$make oldconfig
	fi
	$make -j$(nproc) Image modules dtbs || die "make kernel"
	if test "$__tftp_setup" = "yes"; then
		if test -n "$INITRD_OVL"; then
			# Assume module update is needed
			$me initrd_build
		else
			$me tftp_setup
		fi
	fi
}
##   install_modules <dest>
##     Install kernel modules in the dest directory
cmd_install_modules() {
	test -n "$1" || die "No dest directory"
	test -d "$1" || mkdir -p $1 || die "Failed [mkdir -p $1]"
	INSTALL_MOD_PATH=$1 make -j$(nproc) -C $__kobj modules_install \
		1>&2 > /dev/null || die "Failed to install modules from [$__kobj]"
}
##   lsmod
##     List modules built (not loaded) in the kernel
cmd_lsmod() {
	mkdir -p $tmp
	cmd_install_modules $tmp
	find $tmp -name '*.ko' | grep -oE '[^/]+.ko$'
}
##   busybox_build [--bbcfg=] [--menuconfig] [--local]
##     Build BusyBox for target aarch64-linux-gnu-, unless --local is used
cmd_busybox_build() {
	if test "$__local" = "yes"; then
		WS=$WS/local
		mkdir -p $WS
	fi
	cdsrc $ver_busybox
	if test "$__menuconfig" = "yes"; then
		test -r $__bbcfg && cp $__bbcfg ./.config
		make menuconfig
		cp ./.config $__bbcfg
	else
		test -r $__bbcfg || die "No config"
		cp $__bbcfg ./.config
	fi
	test "$__local" != "yes" && \
		sed -i -E "s,CONFIG_CROSS_COMPILER_PREFIX=\"\",CONFIG_CROSS_COMPILER_PREFIX=\"$__arch-linux-gnu-\"," .config
	make -j$(nproc) || die make
	test "$__local" = "yes" && log "Built [$PWD/busybox]"
	return 0
}
##   initrd_build [--initrd=] [--env=file] [ovls...]
##     Build a ramdisk (cpio archive) with busybox and the passed
##     ovls (a'la xcluster)
cmd_initrd_build() {
	local bb=$WS/$ver_busybox/busybox
	test -x $bb || die "Not executable [$bb]"
	touch $__initrd || die "Can't create [$__initrd]"

	cmd_gen_init_cpio
	gen_init_cpio=$WS/bin/gen_init_cpio
	mkdir -p $tmp
	cat > $tmp/cpio-list <<EOF
dir /dev 755 0 0
nod /dev/console 644 0 0 c 5 1
dir /bin 755 0 0
file /bin/busybox $bb 755 0 0
slink /bin/sh busybox 755 0 0
EOF
	if test -n "$1" -o -n "$INITRD_OVL"; then
		cmd_unpack_ovls $tmp/root $INITRD_OVL $@
		if test -n "$__env"; then
			test -r "$__env" || die "Not readable [$__env]"
			mkdir -p $tmp/root/etc
			cp $__env $tmp/root/etc/env
		fi
		cmd_emit_list $tmp/root >> $tmp/cpio-list
	else
		cat >> $tmp/cpio-list <<EOF
dir /etc 755 0 0
file /init $dir/config/init-tiny 755 0 0
EOF
	fi
	$gen_init_cpio $tmp/cpio-list | gzip -c > $__initrd
	#zcat $__initrd | cpio -i --list
	test "$__tftp_setup" = "yes" && $me tftp_setup
}
#   gen_init_cpio
#     Build the kernel gen_init_cpio utility
cmd_gen_init_cpio() {
	local x=$WS/bin/gen_init_cpio
	test -x $x && return 0
	cmd_kernel_unpack
	mkdir -p $(dirname $x)
	local src=$__kdir/usr/gen_init_cpio.c
	test -r $src || die "Not readable [$src]"
	gcc -o $x $src
}
#   unpack_ovls <dst> [ovls...]
#     Unpack ovls to the <dst> dir
cmd_unpack_ovls() {
	test -n "$1" || die "No dest"
	test -e $1 -a ! -d "$1" && die "Not a directory [$1]"
	mkdir -p $1 || die "Failed mkdir [$1]"
	local ovl d=$1
	shift
	for ovl in $@; do
		test -x $ovl/tar || die "Not executable [$ovl/tar]"
		$ovl/tar - | tar -C $d -x || die "Unpack [$ovl]"
	done
}
#   emit_list <src>
#     Emit a gen_init_cpio list built from the passed <src> dir
cmd_emit_list() {
	test -n "$1" || die "No source"
	local x p d=$1
	test -d $d || die "Not a directory [$d]"
	cd $d
	for x in $(find . -mindepth 1 -type d | cut -c2-); do
		p=$(stat --printf='%a' $d$x)
		echo "dir $x $p 0 0"
	done
	for x in $(find . -mindepth 1 -type f | cut -c2-); do
		p=$(stat --printf='%a' $d$x)
		echo "file $x $d$x $p 0 0"
	done
}
##   collect_ovls [ovls...]
##     Collect ovl's to the --httproot
cmd_collect_ovls() {
	mkdir -p $__httproot || dir "mkdir -p $__httproot"
	local out=$__httproot/ovls.txt
	rm $(find $__httproot -name '*.tar') $out 2> /dev/null
	local ovl i=1 f
	for ovl in $@; do
		f=$(printf "%02d%s.tar" $i $(basename $ovl))
		echo $f >> $out
		i=$((i + 1))
		test -x $ovl/tar || die "Not executable [$ovl/tar]"
		$ovl/tar $__httproot/$f || die "Failed [$ovl]"
	done
}
##   dhcpd --conf=file [--restart]
##   dhcpd --dev= --local-addr=ipv4/24 [--dns=] [--restart]
##     Start "busybox udhcpd" as dhcp server. If --conf is NOT specified
##     a config is generated from --dev, --dns and --local-addr
cmd_dhcpd() {
	test -n "$__dev" || die "No wired interface specified"
	if ! test -x $__busybox; then
		# Try system installed busybox
		if which busybox > /dev/null; then
			__busybox=busybox
		else
			die 'BusyBox not found. Set the $__busybox variable'
		fi
	fi
	$__busybox udhcpd -h 2>&1 | grep -q Usage: || \
		die "busybox udhcpd applet not supported"

	local leases=$WS/udhcpd.leases
	if test -r /var/run/udhcpd.pid; then
		local pid=$(cat /var/run/udhcpd.pid)
		if test "$__restart" = "yes"; then
			log "Killing server pid [$pid] ..."
			sudo kill $pid
			sleep 0.2
			test -r /var/run/udhcpd.pid && die "udhcpd refuses to die"
			sudo rm -f $leases
		else
			log "busybox udhcpd already running as pid $pid"
			return 0
		fi
	fi

	if test -z "$__conf"; then
		check_local_addr
		test -n "$__dns" || __dns=10.0.10.1
		__conf=$WS/udhcpd.conf
		local serverip=$(echo $__local_addr | cut -d/ -f1)
		local rng=$(echo $__local_addr | cut -d. -f1-3)
		sed -e "s,eth0,$__dev," -e "s,/tmp/udhcpd.leases,$leases," \
			-e "s,10.0.0.1,$serverip," -e "s,10.0.0.100,$rng.100," \
			-e "s,10.0.0.200,$rng.200," -e "s,10.0.10.1,$__dns," \
			< $dir/config/udhcpd.conf > $__conf
	fi
	touch $leases
	sudo $__busybox udhcpd -S $__conf || die "udhcpd"
	sleep 0.2
	test -r /var/run/udhcpd.pid || die "dhcpd not started"
}
##   atftp_build
##     Build atftp
cmd_atftp_build() {
	cdsrc $ver_atftp
	test -x "./atftpd" && return 0     # (already built)
	./autogen.sh || die autogen
	./configure || die configure
	make -j$(nproc) || die make
}
##   tftpd --local-addr=ipv4/24 [--restart]
##     Start a tftpd server. Prerequisite: "atftp" is built
cmd_tftpd() {
	if pidof atftpd > /dev/null; then
		local pid=$(pidof atftpd)
		if test "$__restart" = "yes"; then
			log "Killing server pid [$pid]"
			sudo kill $pid
			sleep 0.2
			pidof atftpd > /dev/null && die "Server refuses to die"
		else
			log "Tftpd (atftpd) already started as pid $pid"
			return 0
		fi
	fi
	check_local_addr
	local d=$WS/$ver_atftp
	test -x $d/atftpd || die "Not executable [$d/atftpd]"
	mkdir -p "$__tftproot"
	local adr=$(echo $__local_addr | cut -d/ -f1)
	sudo $d/atftpd --daemon --bind-address $adr $__tftproot
	log "Logs to syslog, tftproot=$__tftproot"
}
# Copy kernel, initrd and dtb to a dest
cp_bootfiles() {
	test -r $kernel || die "Not readable [$kernel]"
	cp $kernel $1/Image
	test -r $__initrd || die "Not readable [$__initrd]"
	cp $__initrd $1/initrd
	test -r $dtb || die "Not readable [$dtb]"
	cp $dtb $1/rock.dtb
}
##   tftp_setup [--pxe-file=default]
##     Copy files from to the tftp-boot directory
cmd_tftp_setup() {
	test -n "$__pxe_file" || __pxe_file=default
	rm -rf $__tftproot/*
	local d=$__tftproot/pxelinux.cfg
	mkdir -p $d
	cp config/pxelinux.cfg $d/$__pxe_file
	cp_bootfiles $__tftproot
}
# Setup a loop device and define $__dev
loop_setup() {
	__dev=$($disk loop-setup)
	test -n "$__dev" || die "loop-setup"
	export __dev
}
# Mount a partition and define $__p and $mnt
pmount() {
	export __p=$1
	mnt=$($disk mount)
	test -n "$mnt" || die "mount partition [$__p]"
}
##   update-bootscr [--sdimage=sdimage] --bootscr=script
##     Update "boot.scr" on the image
cmd_update_bootscr() {
	test -n "$__bootscr" || die "--bootscr not defined"
	test -r $__bootscr || die "Not readable [$__bootscr]"
	test -r $__sdimage || die "Not readable [$__sdimage]"
	mkdir -p $tmp
	local mkimage=$__ubootobj/tools/mkimage
	test -x $mkimage || mkimage=$dir/bin/mkimage
	$mkimage -T script -d $__bootscr $tmp/boot.scr || die $mkimage
	export __image=$__sdimage
	loop_setup
	pmount 1
	if test -r $mnt/boot.scr; then
		log "Updating boot.scr ..."
		cp $tmp/boot.scr $mnt
	else
		log "ERROR: No boot.scr to update!"
	fi
	$disk unmount -b $__dev
	$disk loop-delete
}
##   set_serverip --local-addr=ipv4/24 [--sdimage=]
##   set_serverip [--sdimage=] serverip
##     Set the serverip in "boot.scr" on the image
cmd_set_serverip() {
	local serverip
	if test -n "$1"; then
		serverip=$1
	else
		check_local_addr
		serverip=$(echo $__local_addr | cut -d/ -f1)
	fi
	test -r "$__sdimage" || die "Not readable [$__sdimage]"
	mkdir -p $tmp
	__bootscr=$tmp/u-boot.scr
	sed -e "s,10.0.0.1,$serverip," < config/u-boot.scr > $__bootscr
	cmd_update_bootscr
}
##   sdimage [--sdimage=] [--boot-files]
##     Create an image to be copied to SD. To include kernel, intrd and fdt
##     use "--boot-files". This is NOT needed if PXE boot is used!
##     Assuming SD on /dev/sdb, and $sdimage ponts to the image:
##     sudo dd if=$sdimage of=/dev/sdb status=progress oflag=dsync bs=4M
cmd_sdimage() {
	local uboot=$__ubootobj/u-boot-rockchip.bin
	test -r $uboot || die "Not readable [$uboot]"
	rm -f $__sdimage
	truncate -s 54MiB $__sdimage || die "Failed to create [$__sdimage]"
	dd if=$uboot of=$__sdimage bs=512 seek=64 conv=notrunc
	sfdisk --no-tell-kernel $__sdimage <<EOF
label: gpt
32768,34MiB,U,*
EOF
	export __image=$__sdimage
	$disk mkfat || die "mkfat"
	loop_setup
	log "Dev $__dev"
	pmount
	local mkimage=$__ubootobj/tools/mkimage
	$mkimage -T script -d config/u-boot.scr $mnt/boot.scr
	test "$__boot_files" = "yes" && cp_bootfiles $mnt
	ls $mnt
	$disk unmount || die "unmount"
	$disk loop-delete || die "loop-delete"
	rm -f $__sdimage.xz
	xz --keep $__sdimage
	log "Created [$__sdimage.xz]"
	if test -n "$__local_addr"; then
		check_local_addr
		cmd_set_serverip
		log "Serverip set in [$__sdimage]"
	fi
}
##
# Get the command
cmd=$(echo $1 | tr -- - _)
shift
grep -q "^cmd_$cmd()" $0 $hook || die "Invalid command [$cmd]"

while echo "$1" | grep -q '^--'; do
	if echo $1 | grep -q =; then
		o=$(echo "$1" | cut -d= -f1 | sed -e 's,-,_,g')
		v=$(echo "$1" | cut -d= -f2-)
		eval "$o=\"$v\""
	else
		if test "$1" = "--"; then
			shift
			break
		fi
		o=$(echo "$1" | sed -e 's,-,_,g')
		eval "$o=yes"
	fi
	long_opts="$long_opts $o"
	shift
done
unset o v
long_opts=`set | grep '^__' | cut -d= -f1`

# Execute command
trap "die Interrupted" INT TERM
cmd_env
cmd_$cmd "$@"
status=$?
rm -rf $tmp
exit $status
