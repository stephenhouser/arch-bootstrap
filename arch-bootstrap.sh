#!/bin/bash

# Mini-MAME Arch Install
# DEFAULT VALUES HERE
hostname=mini-mame
user=mame
password=mame
wire_net=enp1s0f0

configure_wifi=
wifi_net=wlp2s0
wifi_ssid=wifi
wifi_pass=password

# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:
#   curl -sL https://git.io/JLHOp | bash

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

### Get infomation from user ###
hostname=$(whiptail --inputbox "Enter hostname" 0 0 ${hostname}) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(whiptail --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
clear

fstype=$(whiptail --menu "Select root file system type" 0 0 0 f2fs "- For SSDs" ext4 "- For HDDs") || exit 1
clear
: ${fstype:?"fstype cannot be empty"}

wire_net=$(whiptail --inputbox "Enter wired network device" 0 0 ${wire_net}) || exit 1
clear
: ${wire_net:?"Wired network device cannot be empty"}

configure_wifi=$(whiptail --yesno "Configure WiFi?" 0 0) || exit 1
clear
if ${configure_wifi}; then
	wifi_net=$(whiptail --inputbox "Enter wireless network device" 0 0 ${wifi_net}) || exit 1
	clear
	: ${wifi_net:?"Wireless network device cannot be empty"}

	wifi_ssid=$(whiptail --inputbox "Enter WiFi ssid" 0 0 ${wifi_ssid}) || exit 1
	clear
	: ${wifi_ssid:?"WiFi ssid cannot be empty"}

	wifi_password=$(whiptail --passwordbox "Enter WiFi password" 0 0 ${wifi_password}) || exit 1
	clear
	: ${wifi_password:?"WiFi password cannot be empty"}
fi

user=$(whiptail --inputbox "Enter admin username" 0 0 ${user}) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(whiptail --passwordbox "Enter admin password" 0 0 ${password}) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(whiptail --stdout --passwordbox "Enter admin password again" 0 0 ${password}) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true

### Setup the disk and partitions ###
echo ""
echo "Partitioning..."
swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
swap_end=$(( $swap_size + 129 + 1 ))MiB

parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 129MiB \
  set 1 boot on \
  mkpart primary linux-swap 129MiB ${swap_end} \
  mkpart primary ext4 ${swap_end} 100%

# Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1
# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

echo ""
echo "Creating file systems..."
wipefs "${part_boot}"
wipefs "${part_swap}"
wipefs "${part_root}"

mkfs.vfat -F32 "${part_boot}"
mkswap "${part_swap}"
mkfs.${fstype} -f "${part_root}"

echo ""
echo "Mount new filesystems..."
swapon "${part_swap}"
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

echo ""
echo "Botstrapping the root volume..."
pacstrap /mnt \
	linux linux-firmware linux-headers intel_ucode \
	base base-devel \
	efibootmgr \
	dhcpcd broadcom-wl-dkms wpa_supplicant \
	e2fsprogs exfatprogs f2fs-tools dosfstools ntfs-3g \
	openssh \
	man-db man-pages \
	sudo vim zsh git

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

# wifi working
cat >> /mnt/etc/wpa_supplicant/wpa_supplicant.conf << EOF
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
	ssid="${wifi_ssid}"
	password="${wifi_password}"
}
EOF
arch-chroot /mnt ln -s /usr/share/dhcpcd/hooks/10-wpa_supplicant /usr/lib/dhcpcd/dhcpcd-hooks/
arch-chroot /mnt systemctl enable wpa_supplicant.service
fi

arch-chroot /mnt systemctl enable systemd-networkd.service
arch-chroot /mnt systemctl enable dhcpcd.service
arch-chroot /mnt systemctl enable sshd.service

# Set up systemd-boot (EFI direct boot)
echo ""
echo "Setting up boot manager and initial ramdisk..."
arch-chroot /mnt mkinitcpio -P
arch-chroot /mnt bootctl --path=/boot install

cat >> /mnt/boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=${PART_ROOT} rw
EOF

# start after power loss
echo ""
echo "Setting up power on after power loss..."
setpci -s 0:1f.0 0xa4.b=0

echo ""
echo "Setting up accounts..."
# change sudoers file so wheel can run
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers

# Root password
echo "root:$password" | chpasswd --root /mnt

# Add user account
arch-chroot /mnt useradd -mU -s /usr/bin/zsh -G  wheel,uucp,video,audio,storage,games,input ${user}
arch-chroot /mnt chsh -s /usr/bin/zsh
echo "${user}:$password" | chpasswd --root /mnt

echo ""
echo "done!"
