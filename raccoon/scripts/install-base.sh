#!/usr/bin/env bash

# stop on errors
set -eu

ROOT_DISK='/dev/sda'

HOSTNAME='raccoon'
KEYMAP='us'
LANGUAGE='en_US.UTF-8'
PASSWORD=$(/usr/bin/openssl passwd -crypt 'vagrant')
TIMEZONE='Europe/Minsk'

CONFIG_SCRIPT='/usr/local/bin/arch-config.sh'

ADMIN_USERNAME="tanuki"
ADMIN_PASSWORD="tanuki"

EFI_PARTITION="${ROOT_DISK}1"
SWAP_PARTITION="${ROOT_DISK}2"
ROOT_PARTITION="${ROOT_DISK}3"
TARGET_DIR='/mnt'
COUNTRY=${COUNTRY:-US}
MIRRORLIST="https://archlinux.org/mirrorlist/?country=${COUNTRY}&protocol=http&protocol=https&ip_version=4&use_mirror_status=on"

echo "=> base: Clearing partition table on ${ROOT_DISK}.."
/usr/bin/sgdisk --zap ${ROOT_DISK}

echo "=> base: Destroying magic strings and signatures on ${ROOT_DISK}.."
/usr/bin/dd if=/dev/zero of=${ROOT_DISK} bs=512 count=2048
/usr/bin/wipefs --all ${ROOT_DISK}

echo "=> base: Creating /efi partition on ${EFI_PARTITION}.."
/usr/bin/sgdisk --new=1:1Mib:+512Mib ${ROOT_DISK}
sgdisk -t 1:ef00 ${EFI_PARTITION}

echo "=> base: Creating /swap partition on ${SWAP_DISK}.."
/usr/bin/sgdisk --new=2:0:+4096Mib ${ROOT_DISK}

echo "=> base: Creating / partition on ${ROOT_DISK}.."
/usr/bin/sgdisk --new=3:0:0 ${ROOT_DISK}

echo "=> base: Setting ${ROOT_DISK} bootable.."
/usr/bin/sgdisk ${ROOT_DISK} --attributes=1:set:2

echo "=> base: Creating /efi filesystem (fat32).."
/usr/bin/mkfs.fat -F 32 -L efi ${EFI_PARTITION}

echo "=> base: Creating /swap filesystem (swap).."
/usr/bin/mkswap -L swap ${SWAP_PARTITION}

echo "=> base: Creating / filesystem (ext4).."
/usr/bin/mkfs.ext4 -L root ${ROOT_PARTITION}

## Bootstrap

echo "=> base: Mounting ${ROOT_PARTITION} to ${TARGET_DIR}.."
/usr/bin/mount -o noatime,errors=remount-ro ${ROOT_PARTITION} ${TARGET_DIR}

echo "=> base: Mounting ${EFI_PARTITION} partition to ${TARGET_DIR}/boot/"
/usr/bin/mount -o noatime,errors=remount-ro ${EFI_PARTITION} ${TARGET_DIR}/boot

echo "=> base: Mounting /swap partition"
/usr/bin/swapon ${SWAP_PARTITION}

echo "=> base: Setting pacman ${COUNTRY} mirrors.."
curl -s "$MIRRORLIST" |  sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist

echo "=> base: Bootstrapping the base installation.."
/usr/bin/pacstrap ${TARGET_DIR} base linux

echo "=> base: Installing basic packages.."
/usr/bin/arch-chroot ${TARGET_DIR} pacman -S --noconfirm openssh syslinux dhcpcd

## Setting bootmanager

echo "=> base: Configuring syslinux.."
/usr/bin/arch-chroot ${TARGET_DIR} syslinux-install_update -i -a -m
/usr/bin/sed -i "s|sda3|${ROOT_PARTITION##/dev/}|" "${TARGET_DIR}/boot/syslinux/syslinux.cfg"
/usr/bin/sed -i 's/TIMEOUT 50/TIMEOUT 5/' "${TARGET_DIR}/boot/syslinux/syslinux.cfg"

echo "=> base: Generating the filesystem table.."
/usr/bin/genfstab -p ${TARGET_DIR} >> "${TARGET_DIR}/etc/fstab"

echo "=> base: Generating the system configuration script.."
/usr/bin/install --mode=0755 /dev/null "${TARGET_DIR}${CONFIG_SCRIPT}"

CONFIG_SCRIPT_SHORT=`basename "$CONFIG_SCRIPT"`
cat <<-EOF > "${TARGET_DIR}${CONFIG_SCRIPT}"
    echo "=> rootfs: Configuring hostname, timezone, and keymap.."
    echo '${HOSTNAME}' > /etc/hostname

    /usr/bin/ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
    echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf

    echo "=> rootfs: Configuring locale.."
    /usr/bin/sed -i 's/#${LANGUAGE}/${LANGUAGE}/' /etc/locale.gen
    /usr/bin/locale-gen

    echo "=> rootfs: ${CONFIG_SCRIPT_SHORT}: Creating initramfs.."
    /usr/bin/mkinitcpio -p linux

    echo "=> rootfs: ${CONFIG_SCRIPT_SHORT}: Setting root pasword.."
    /usr/bin/usermod --password ${PASSWORD} root

    echo "=> rootfs: ${CONFIG_SCRIPT_SHORT}: Configuring network.."
    # Disable systemd Predictable Network Interface Names and revert to traditional interface names
    /usr/bin/ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules
    /usr/bin/systemctl enable dhcpcd@eth0.service

    echo "=> rootfs:  Configuring sshd.."
    /usr/bin/sed -i 's/#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
    /usr/bin/systemctl enable sshd.service

    # # Workaround for https://bugs.archlinux.org/task/58355 which prevents sshd to accept connections after reboot
    # echo "=> rootfs:  Adding workaround for sshd connection issue after reboot.."
    # /usr/bin/pacman -S --noconfirm rng-tools
    # /usr/bin/systemctl enable rngd

    # Vagrant-specific configuration
    echo "=> rootfs:  Creating vagrant user.."
    /usr/bin/useradd --password ${PASSWORD} --comment 'Vagrant User' --create-home --user-group vagrant
    echo "=> rootfs:  Configuring sudo.."
    echo 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/10_vagrant
    echo 'vagrant ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/10_vagrant
    /usr/bin/chmod 0440 /etc/sudoers.d/10_vagrant

    echo "=> rootfs:  Configuring ssh access for vagrant.."
    /usr/bin/install --directory --owner=vagrant --group=vagrant --mode=0700 /home/vagrant/.ssh
    /usr/bin/curl --output /home/vagrant/.ssh/authorized_keys --location https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub
    /usr/bin/chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
    /usr/bin/chmod 0600 /home/vagrant/.ssh/authorized_keys

    echo "=> rootfs:  Creating tanuki user.."
    /usr/bin/useradd --password ${ADMIN_PASSWORD} --comment 'Tanuki User' --create-home --user-group vagrant --groups wheel,adm {ADMIN_USERNAME}
    echo "=> rootfs:  Configuring sudo.."
    /usr/bin/sed -i 's/#%wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

    echo "=> rootfs:  Cleaning up.."
    /usr/bin/pacman -Rcns --noconfirm gptfdisk
EOF

echo "=> base: Entering chroot and configuring system.."
/usr/bin/arch-chroot ${TARGET_DIR} ${CONFIG_SCRIPT}
rm "${TARGET_DIR}${CONFIG_SCRIPT}"

# http://comments.gmane.org/gmane.linux.arch.general/48739
echo "=> base: Adding workaround for shutdown race condition.."
/usr/bin/install --mode=0644 /root/poweroff.timer "${TARGET_DIR}/etc/systemd/system/poweroff.timer"

echo "=> base: Completing installation.."
/usr/bin/sleep 3
/usr/bin/umount ${TARGET_DIR}

echo '==> Turning down network interfaces and rebooting'
for i in $(/usr/bin/netstat -i | /usr/bin/tail +3 | /usr/bin/awk '{print $1}'); do /usr/bin/ip link set ${i} down; done
/usr/bin/systemctl reboot
echo "=> base: Installation complete!"