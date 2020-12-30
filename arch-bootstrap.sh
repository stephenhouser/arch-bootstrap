#!/bin/bash
# Mini-MAME Arch Install

# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:
#   curl -sL https://git.io/JLHZM | bash
# Based heavily on https://disconnected.systems/blog/archlinux-installer/#the-complete-installer-script

# DEFAULT VALUES HERE -- IF SET YOU WILL NOT GET PROPMTED
hostname=mini-mame
disk=/dev/sda
part_root=/dev/sda3
part_swap=/dev/sda2
#fstype=f2fs

#wire_net=enp1s0f0

#configure_wifi=0
#wifi_net=wlp2s0
#wifi_ssid=wifi
#wifi_pass=password
#wifi_psk="psk"

#rootpass=none
#user=mame
#password=mame

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

### Get infomation from user ###
if [ -z ${hostname+x} ]; then
	hostname=$(whiptail --inputbox "Enter hostname" 10 50 3>&1 1>&2 2>&3) || exit 1
	: ${hostname:?"hostname cannot be empty"}
fi

if [ -z ${disk+x} ]; then
	SAVE_IFS=${IFS}
	IFS=$'\n'
	blockdevices=()
	for dev in $(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac); do
		dev_name=$(echo $dev | awk -e '{print $1}')
		dev_size=$(echo $dev | awk -e '{print $2}')
		blockdevices+=("${dev_name}" "    ${dev_size}")
	done
	IFS=${SAVE_IFS}
	disk=$(whiptail --menu "Select installation disk" 10 50 0 "${blockdevices[@]}" 3>&1 1>&2 2>&3) || exit 1
fi

if [ -z ${fstype+x} ]; then
	fstypes=()
	fstypes+=("f2fs" "    Best for SSDs")
	fstypes+=("ext4" "    Best for HDDs")
	fstype=$(whiptail --menu "Select root file system type" 10 50 0 "${fstypes[@]}" 3>&1 1>&2 2>&3) || exit 1
	: ${fstype:?"fstype cannot be empty"}
fi

netdevices=()
for dev in $(ip link show | tac | egrep "^[0-9]+:" | cut -d: -f2); do
	netdevices+=("$dev" " ")
done

if [ -z ${wire_net+x} ]; then
	wire_net=$(whiptail --menu "Select wired network device" 10 50 0 "${netdevices[@]}" 3>&1 1>&2 2>&3) || exit 1
	: ${wire_net:?"Wired network device cannot be empty"}
fi

if [ -z ${configure_wifi+x} ]; then
	configure_wifi=0
	if whiptail --yesno "Configure WiFi?" 0 0; then
		configure_wifi=1
		if [ -z ${wifi_net+x} ]; then
			wifi_net=$(whiptail --menu "Select wireless network device" 10 50 0 "${netdevices[@]}" 3>&1 1>&2 2>&3) || exit 1
			: ${wifi_net:?"Wireless network device cannot be empty"}
		fi

		if [ -z ${wifi_ssid+x} ]; then
			wifi_ssid=$(whiptail --inputbox "Enter WiFi ssid" 10 50 3>&1 1>&2 2>&3) || exit 1
			: ${wifi_ssid:?"WiFi ssid cannot be empty"}
		fi

		if [ -z ${wifi_password+x} ]; then
			wifi_password=$(whiptail --passwordbox "Enter WiFi password" 10 50 3>&1 1>&2 2>&3) || exit 1
			: ${wifi_password:?"WiFi password cannot be empty"}
		fi
	fi
fi

if [ -z ${rootpass+x} ]; then
	rootpass=$(whiptail --passwordbox "Enter root password" 10 50 3>&1 1>&2 2>&3) || exit 1
	: ${rootpass:?"root's password cannot be empty"}
	rootpass2=$(whiptail --passwordbox "Enter root password again" 10 50 3>&1 1>&2 2>&3) || exit 1
	[[ "$rootpass" == "$rootpass2" ]] || ( echo "Passwords did not match"; exit 1; )
fi

if [ -z ${user+x} ]; then
	user=$(whiptail --inputbox "Enter admin username" 10 50 ${user} 3>&1 1>&2 2>&3) || exit 1
	: ${user:?"user cannot be empty"}
fi

if [ -z ${password+x} ]; then
	password=$(whiptail --passwordbox "Enter admin password" 10 50 ${password} 3>&1 1>&2 2>&3) || exit 1
	: ${password:?"password cannot be empty"}
	password2=$(whiptail --passwordbox "Enter admin password again" 10 50 ${password} 3>&1 1>&2 2>&3) || exit 1
	[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )
fi

[ -d /sys/firmware/efi ] && firmware=UEFI || firmware=BIOS

clear
cat >> /tmp/settings.$$ >> EOF
hostname=${hostname}
disk=${disk}
part_root=${part_root}
part_swap=${part_swap}
fstype=${fstype}
firmware=${firmware}
wire_net=${wire_net}
configure_wifi=${configure_wifi}
wifi_net=${wifi_net}
wifi_ssid=${wifi_ssid}
wifi_pass=${wifi_pass}
wifi_psk=${wifi_psk}
rootpass=${rootpass}
user=${user}
password=${password}
*** Ready to apply ***
EOF

whiptail --textbox /tmp/settings.$$ || exit 1

exit 2

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true

### Setup the disk and partitions ###
# if part_root defined, then use it and don't re-partition
if [ -z ${part_root+x} ]; then
	echo ""
	echo "Partitioning..."
	swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
	swap_end=$(( $swap_size + 129 + 1 ))MiB

	[ "${firmware}" == "UEFI" ] && boot_fstype=ESP || boot_fstype=primary

	parted --script "${disk}" -- mklabel gpt \
		mkpart ${boot_fstype} fat32 1Mib 129MiB \
		set 1 boot on \
		mkpart primary linux-swap 129MiB ${swap_end} \
		mkpart primary ext4 ${swap_end} 100%

	# Simple globbing was not enough as on one disk I needed to match /dev/mmcblk0p1
	# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other disks.
	part_boot="$(ls ${disk}* | grep -E "^${disk}p?1$")"
	part_swap="$(ls ${disk}* | grep -E "^${disk}p?2$")"
	part_root="$(ls ${disk}* | grep -E "^${disk}p?3$")"
fi

echo ""
echo "Creating and activating file systems..."
if [ ! -z ${part_swap+x} ]; then
	wipefs "${part_swap}"
	mkswap "${part_swap}"
	swapon "${part_swap}"
fi

wipefs "${part_root}"
mkfs.${fstype} -f "${part_root}"
mount "${part_root}" /mnt

if [ ! -z ${part_boot+x} ]; then
	wipefs "${part_boot}"
	mkfs.vfat -F32 "${part_boot}"
	mkdir /mnt/boot
	mount "${part_boot}" /mnt/boot
fi

echo ""
echo "Botstrapping the root volume..."
# Check for EFI firmware (vs BIOS)
if [ "${firmware}" == "UEFI" ]; then
	# efibootmgr		-- for manipulating UEFI boot order systemd-boot
	bootloader_packages="efibootmgr"
else
	# grub				-- The GRUB bootloader
	bootloader_packages="grub"
fi

# linux linux-firmware 	-- the kernel
# linux-headers 		-- allows building and dynamic build kernel modules
# intel-ucide 			-- indel microcode updates
# base base-devel 		-- base GNU/Linux and development tools
# dhcpcd				-- DHCP Client
# wpa_supplicant		-- WPA WiFi authentication
# broadcom-wl-dkms 		-- Mac mini wireless driver
# e2fsprogs				-- ext based file systems
# exfatprogs			-- MS-DOS FAT based file systems
# dosfstools			-- MS-DOS FAT based file systems
# f2fs-tools			-- F2FS Flash-based file systems
# ntfs-3g				-- NTFS-based file systems
# openssh				-- SSH client and server
# man-db man-pages		-- The manual
# pkgfile 				-- allows finding which package provides a program
# zsh grml-zsh-confit	-- zsh and pre-configured zsh scripts
# sudo					-- sudo command 
# vim					-- the editor
# screen				-- terminal multiplexer
# git					-- source code control
# libnewt 				-- whiptail for text-mode prompts

pacstrap /mnt \
	linux linux-firmware linux-headers intel-ucode \
	${bootloader_packages} \
	base base-devel \
	dhcpcd wpa_supplicant broadcom-wl-dkms \
	e2fsprogs exfatprogs f2fs-tools dosfstools ntfs-3g \
	openssh \
	pkgfile libnewt \
	man-db man-pages \
	zsh grml-zsh-config \
	sudo vim git screen 

genfstab -t PARTUUID /mnt >> /mnt/etc/fstab

echo ""
echo "Setting up timezone and locale..."
arch-chroot /mnt ln -sf /usr/share/zoneinfo/US/Eastern /etc/localtime
arch-chroot /mnt hwclock --systohc
arch-chroot /mnt systemctl enable systemd-timesyncd.service

echo en_US.UTF-8 UTF-8 >> /mnt/etc/locale.gen
echo LANG=en_US.UTF-8 >> /mnt/etc/locale.conf
arch-chroot /mnt locale-gen

echo ""
echo "Setting up hostname and hosts..."
echo mini-mame >> /mnt/etc/hostname
cat >> /mnt/etc/hosts << EOF	
127.0.0.1 localhost
::1 localhost
127.0.0.1 mini-mame.localdomain mini-mame
EOF

echo ""
echo "Setting up network..."
cat >> /mnt/etc/systemd/network/10-${wire_net}.network << EOF
[Match]
${wire_net}

[Network]
DHCP=yes
EOF

if ${configure_wifi}; then
	cat >> /mnt/etc/systemd/network/20-${wifi_net}.network << EOF
[Match]
${wifi_net}

[Network]
DHCP=yes

[DHCP]
RouteMetric=20
EOF

	if [ -z ${wifi_psk+x} ]; then
		wpa_pass_line="password=\"${wifi_password}\""
	else
		wpa_pass_line="psk=\"${wifi_psk}\""
	fi

	# wifi working
	cat >> /mnt/etc/wpa_supplicant/wpa_supplicant.conf << EOF
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
	ssid="${wifi_ssid}"
	${wpa_pass_line}
}
EOF

	arch-chroot /mnt ln -s /usr/share/dhcpcd/hooks/10-wpa_supplicant /usr/lib/dhcpcd/dhcpcd-hooks/
	arch-chroot /mnt systemctl enable wpa_supplicant.service
fi

# enable network services...
arch-chroot /mnt systemctl enable systemd-networkd.service
arch-chroot /mnt systemctl enable dhcpcd.service
arch-chroot /mnt systemctl enable sshd.service

echo ""
echo "Setting up accounts..."
# change sudoers file so wheel can run
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers

# Root password
echo "root:$rootpass" | chpasswd --root /mnt

# Add user account
arch-chroot /mnt useradd -mU -s /usr/bin/zsh -G  wheel,uucp,video,audio,storage,games,input ${user}
arch-chroot /mnt chsh -s /usr/bin/zsh
echo "${user}:$password" | chpasswd --root /mnt

echo ""
echo "Setting up packages..."
arch-chroot /mnt pkgfile -u

# Set up systemd-boot (EFI direct boot)
echo ""
echo "Setting up boot manager and initial ramdisk..."
arch-chroot /mnt mkinitcpio -P

if [ "${firmware}" == "UEFI" ]; then
	arch-chroot /mnt bootctl --path=/boot install
	cat >> /mnt/boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=${part_root} rw
EOF

	# start after power loss
	echo ""
	echo "Setting up power on after power loss..."
	setpci -s 0:1f.0 0xa4.b=0
else
	arch-chroot /mnt grub-install ${disk}
fi

#echo ""
#echo "Unmounting..."
#umount ${part_boot}
#umount ${part_root}

echo ""
echo "done!"
