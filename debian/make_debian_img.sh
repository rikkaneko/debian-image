#!/bin/sh

# Copyright (C) 2025, John Clark <inindev@gmail.com>

set -e

# script exit codes:
#   1: missing utility
#   2: download failure
#   3: image mount failure
#   4: missing file
#   5: invalid file hash
#   9: superuser required

main() {
    # file media is sized with the number between 'mmc_' and '.img'
    #   use 'm' for 1024^2 and 'g' for 1024^3
    local media='base_mmc_2g.img'
    local deb_dist='trixie'
    local hostname="${PI_HOSTNAME:-${deb_dist}-arm64}"
    local acct_uid="${PI_USERNAME:-debian}"
    local acct_pass="${PI_PASSWORD:-debian}"
    local extra_pkgs="${PI_EXTRA_PKGS:-}"
    local ssh_key="${PI_SSH_KEY:-}"

    if is_param 'clean' "$@"; then
        rm -rf cache*/var
        rm -f "$media"*
        rm -rf "$mountpt"
        echo -e '\nclean complete\n'
        exit 0
    fi

    check_installed 'debootstrap' 'wget' 'xz' 'rsync'

    if [ -f "$media" ]; then
        read -p "file $media exists, overwrite? <y/N> " yn
        if ! [ "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo -e 'exiting...'
            exit 0
        fi
    fi

    print_hdr 'downloading files'
    local cache="cache.$deb_dist"

    # linux firmware
    local lfw=$(download "$cache" 'https://mirrors.edge.kernel.org/pub/linux/kernel/firmware/linux-firmware-20250808.tar.xz')
    local lfwsha='c029551b45a15926c9d7a5df1a0b540044064f19157c57fc11d91fd0aade837f'
    [ "$lfwsha" = $(sha256sum "$lfw" | cut -c1-64) ] || { echo -e "invalid hash for $lfw"; exit 5; }

    # setup media
    print_hdr 'creating image file'
    make_image_file "$media"

    print_hdr 'partitioning media'
    parition_media "$media"

    print_hdr 'formatting media'
    format_media "$media"

    print_hdr 'mounting media'
    mount_media "$media"

    print_hdr 'configuring files'
    sudo install -Dvm 644 'files/kernel-img.conf' "$mountpt/etc/kernel-img.conf"

    print_hdr 'setting up fstab'
    local mdev="$(findmnt -no source "$mountpt")"
    local uuid="$(sudo blkid -o value -s UUID "$mdev")"
    echo -e "$(file_fstab $uuid)\n" | sudo tee "$mountpt/etc/fstab"

    print_hdr 'setting up extlinux boot'
    sudo install -Dvm 754 'files/dtb_cp' "$mountpt/etc/kernel/postinst.d/dtb_cp"
    sudo install -Dvm 754 'files/kernel_chmod' "$mountpt/etc/kernel/postinst.d/kernel_chmod"
    sudo install -Dvm 754 'files/dtb_rm' "$mountpt/etc/kernel/postrm.d/dtb_rm"
    sudo install -Dvm 754 'files/mk_extlinux' "$mountpt/boot/mk_extlinux"
    sudo ln -svf '../../../boot/mk_extlinux' "$mountpt/etc/kernel/postinst.d/update_extlinux"
    sudo ln -svf '../../../boot/mk_extlinux' "$mountpt/etc/kernel/postrm.d/update_extlinux"

    print_hdr 'installing overlay files'
    local dtbos="$(find "$cache/overlays" -maxdepth 1 -name '*.dtbo' 2>/dev/null | sort)"
    if [ -n "$dtbos" ]; then
        local dtbo dtgt="$mountpt/boot/overlay/lib"
        sudo mkdir -pv "$dtgt"
        for dtbo in $dtbos; do
            sudo install -vm 644 "$dtbo" "$dtgt"
        done
    fi

    print_hdr 'installing firmware'
    sudo mkdir -p "$mountpt/usr/lib/firmware"
    local lfwbn=$(basename "$lfw" '.tar.xz')
    sudo tar -C "$mountpt/usr/lib/firmware" --strip-components=1 --wildcards -xavf "$lfw" \
        "$lfwbn/arm/mali/arch10.8" \
        "$lfwbn/microchip" \
        "$lfwbn/nvidia/tegra124" \
        "$lfwbn/nvidia/tegra186" \
        "$lfwbn/nvidia/tegra194" \
        "$lfwbn/nvidia/tegra210" \
        "$lfwbn/rockchip" \
        "$lfwbn/r8a779x_usb3_v[1-3].dlmem" \
        "$lfwbn/rtl_bt" \
        "$lfwbn/rtl_nic" \
        "$lfwbn/rtlwifi" \
        "$lfwbn/rtw88" \
        "$lfwbn/rtw89"

    # install debian linux from deb packages (debootstrap)
    print_hdr 'installing root filesystem from debian.org'

    local pkgs="initramfs-tools, dbus, dhcpcd, libpam-systemd, openssh-server, systemd-timesyncd, \
                rfkill, wireless-regdb, wpasupplicant, bc, curl, pciutils, sudo, unzip, wget, xxd, \
                xz-utils, zip, zstd dnsmasq"
    

    local debian_root="$cache/debootstrap"
    if [ ! -d "$debian_root" ]; then
        print_hdr "building debian root at $debian_root."
        # do not write the cache to the image
        sudo mkdir -p "$cache/var/cache" "$cache/var/lib/apt/lists"
        sudo mkdir -p "$debian_root/var/cache" "$debian_root/var/lib/apt/lists"
        sudo mount -o bind "$cache/var/cache" "$debian_root/var/cache"
        sudo mount -o bind "$cache/var/lib/apt/lists" "$debian_root/var/lib/apt/lists"

        sudo debootstrap --arch arm64 --include "$pkgs, $extra_pkgs" --exclude "isc-dhcp-client" "$deb_dist" "$debian_root" 'https://deb.debian.org/debian/'

        sudo umount "$debian_root/var/cache"
        sudo umount "$debian_root/var/lib/apt/lists"
    else
        print_hdr "found built debian root at $debian_root."
    fi
    sudo rsync -aAXH "$debian_root/" "$mountpt"

    # apt sources & default locale
    echo -e "$(file_apt_sources $deb_dist)\n" | sudo tee "$mountpt/etc/apt/sources.list"
    echo -e "$(file_locale_cfg)\n" | sudo tee "$mountpt/etc/default/locale"

    # enable ll alias
    sudo sed -i '/alias.ll=/s/^#*\s*//' "$mountpt/etc/skel/.bashrc"
    sudo sed -i '/export.LS_OPTIONS/s/^#*\s*//' "$mountpt/root/.bashrc"
    sudo sed -i '/eval.*dircolors/s/^#*\s*//' "$mountpt/root/.bashrc"
    sudo sed -i '/alias.l.=/s/^#*\s*//' "$mountpt/root/.bashrc"

    # motd (off by default)
    is_param 'motd' "$@" && [ -f '../etc/motd' ] && sudo cp -f '../etc/motd' "$mountpt/etc"

    # hostname
    echo -e $hostname | sudo tee "$mountpt/etc/hostname"
    sudo sed -i "s/127.0.0.1\tlocalhost/127.0.0.1\tlocalhost\n127.0.1.1\t$hostname/" "$mountpt/etc/hosts"

    print_hdr 'creating user account'
    sudo chroot "$mountpt" /usr/sbin/useradd -m "$acct_uid" -s '/bin/bash'
    sudo chroot "$mountpt" /bin/sh -c "/usr/bin/echo -e $acct_uid:$acct_pass | /usr/sbin/chpasswd -c YESCRYPT"
    sudo chroot "$mountpt" /usr/bin/passwd -e "$acct_uid"
    (umask 377 && echo -e "$acct_uid ALL=(ALL) NOPASSWD: ALL" | sudo tee "$mountpt/etc/sudoers.d/$acct_uid")

    print_hdr 'installing rootfs expansion script to /etc/rc.local'
    sudo install -Dvm 754 'files/rc.local' "$mountpt/etc/rc.local"

    # disable sshd until after keys are regenerated on first boot
    sudo rm -fv "$mountpt/etc/systemd/system/sshd.service"
    sudo rm -fv "$mountpt/etc/systemd/system/multi-user.target.wants/ssh.service"
    #sudo rm -fv "$mountpt/etc/ssh/ssh_host_"*
    if [ -n "$ssh_key" ]; then
        print_hdr "found ssh key $ssh_key"
        sudo mkdir "$mountpt/home/$acct_uid/.ssh"
        sudo chmod 700 "$mountpt/home/$acct_uid/.ssh"
        echo -e "$ssh_key" | sudo tee "$mountpt/home/$acct_uid/.ssh/authorized_keys"
        sudo chmod 600 "$mountpt/home/$acct_uid/.ssh/authorized_keys"
        sudo chown -R 1000:1000 "$mountpt/home/$acct_uid/.ssh"
    fi

    # Disable DHCP server before configured
    sudo rm -fv "$mountpt/etc/systemd/system/multi-user.target.wants/dnsmasq.service"

    # generate machine id on first boot
    sudo truncate -s0 "$mountpt/etc/machine-id"

    # reduce entropy on non-block media
    [ -b "$media" ] || sudo fstrim -v "$mountpt"

    sudo umount "$mountpt"
    sudo rm -rf "$mountpt"

    chmod 444 "$media" # source image should be treated as immutable
    echo -e "\n${cya}$media image is now ready${rst}"
    echo -e
}

make_image_file() {
    local media="$1"

    rm -f "$media"*
    local size="$(echo -e "$media" | sed -rn 's/.*mmc_([[:digit:]]+[m|g])\.img$/\1/p')"
    truncate -s "$size" "$media"
    stat --printf='image file: %n\nsize: %s bytes\n' "$media"
}

parition_media() {
    local media="$1"

    # partition with gpt
    cat <<-EOF | /usr/sbin/sfdisk "$media"
	label: gpt
	unit: sectors
	first-lba: 2048
	part1: start=32768, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=rootfs
	EOF
    sync
}

format_media() {
    local media="$1"
    local partnum="${2:-1}"

    # create ext4 filesystem
    lodev="$(/usr/sbin/losetup -f)"
    sudo losetup -vP "$lodev" "$media" && sync
    echo -e "loop device $lodev created for image file $media\n"
    echo -e "formatting ${lodev}p${partnum} as ext4\n"
    sudo mkfs.ext4 -L rootfs -vO metadata_csum_seed "${lodev}p${partnum}" && sync
    #losetup -vd "$lodev" && sync
}

mount_media() {
    local media="$1"
    local partnum="1"

    if ! [ -f "$media" ]; then
        echo -e "file not found: $media"
        exit 4
    fi

    if [ -d "$mountpt" ]; then
        mountpoint -q "$mountpt/var/cache" && umount "$mountpt/var/cache"
        mountpoint -q "$mountpt/var/lib/apt/lists" && umount "$mountpt/var/lib/apt/lists"
        mountpoint -q "$mountpt" && umount "$mountpt"
    else
        mkdir -p "$mountpt"
    fi

    sudo mount "${lodev}p${partnum}" "$mountpt"
    if ! [ -d "$mountpt/lost+found" ]; then
        echo -e 'failed to mount the image file'
        exit 3
    fi

    echo -e "media ${cya}$media${rst} partition $partnum successfully mounted on ${cya}$mountpt${rst}"
}

check_mount_only() {
    local item img flag=false
    for item in "$@"; do
        case "$item" in
            mount) flag=true ;;
            *.img) img=$item ;;
            *.img.xz) img=$item ;;
        esac
    done
    ! $flag && return

    if [ ! -f "$img" ]; then
        if [ -z "$img" ]; then
            echo -e "no image file specified"
        else
            echo -e "file not found: ${red}$img${rst}"
        fi
        exit 3
    fi

    if [ "$img" = *.xz ]; then
        local tmp=$(basename "$img" .xz)
        if [ -f "$tmp" ]; then
            echo -e "compressed file ${bld}$img${rst} was specified but uncompressed file ${bld}$tmp${rst} exists..."
            echo -e -n "mount ${bld}$tmp${rst}"
            read -p " instead? <Y/n> " yn
            if ! [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
                echo -e 'exiting...'
                exit 0
            fi
            img=$tmp
        else
            echo -e -n "compressed file ${bld}$img${rst} was specified"
            read -p ', decompress to mount? <Y/n>' yn
            if ! [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
                echo -e 'exiting...'
                exit 0
            fi
            xz -dk "$img"
            img=$(basename "$img" .xz)
        fi
    fi

    echo -e "mounting file ${yel}$img${rst}..."
    mount_media "$img"
    trap - EXIT INT QUIT ABRT TERM
    echo -e "media mounted, use ${grn}sudo umount $mountpt${rst} to unmount"

    exit 0
}

# ensure inner mount points get cleaned up
on_exit() {
    if mountpoint -q "$mountpt"; then
        mountpoint -q "$mountpt/var/cache" && sudo umount "$mountpt/var/cache"
        mountpoint -q "$mountpt/var/lib/apt/lists" && sudo umount "$mountpt/var/lib/apt/lists"

        read -p "$mountpt is still mounted, unmount? <Y/n> " yn
        [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ] || exit 0

        echo -e "unmounting $mountpt"
        sudo umount "$mountpt"
        sync
        rm -rf "$mountpt"
    fi

    sudo losetup -vD
}
mountpt='rootfs'
trap on_exit EXIT INT QUIT ABRT TERM

file_fstab() {
    local uuid="$1"

    cat <<-EOF
	# if editing the device name for the root entry, it is necessary
	# to regenerate the extlinux.conf file by running /boot/mk_extlinux

	# <device>					<mount>	<type>	<options>		<dump> <pass>
	UUID=$uuid	/	ext4	errors=remount-ro	0      1
	EOF
}

file_apt_sources() {
    local deb_dist="$1"

    cat <<-EOF
	# For information about how to configure apt package sources,
	# see the sources.list(5) manual.

	deb http://deb.debian.org/debian ${deb_dist} main contrib non-free non-free-firmware
	#deb-src http://deb.debian.org/debian ${deb_dist} main contrib non-free non-free-firmware

	deb http://deb.debian.org/debian-security ${deb_dist}-security main contrib non-free non-free-firmware
	#deb-src http://deb.debian.org/debian-security ${deb_dist}-security main contrib non-free non-free-firmware

	deb http://deb.debian.org/debian ${deb_dist}-updates main contrib non-free non-free-firmware
	#deb-src http://deb.debian.org/debian ${deb_dist}-updates main contrib non-free non-free-firmware
	EOF
}

file_wpa_supplicant_conf() {
    cat <<-EOF
	ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
	update_config=1
	EOF
}

file_locale_cfg() {
    cat <<-EOF
	LANG="C.UTF-8"
	LANGUAGE=
	LC_CTYPE="C.UTF-8"
	LC_NUMERIC="C.UTF-8"
	LC_TIME="C.UTF-8"
	LC_COLLATE="C.UTF-8"
	LC_MONETARY="C.UTF-8"
	LC_MESSAGES="C.UTF-8"
	LC_PAPER="C.UTF-8"
	LC_NAME="C.UTF-8"
	LC_ADDRESS="C.UTF-8"
	LC_TELEPHONE="C.UTF-8"
	LC_MEASUREMENT="C.UTF-8"
	LC_IDENTIFICATION="C.UTF-8"
	LC_ALL=
	EOF
}

# download / return file from cache
download() {
    local cache="$1"
    local url="$2"

    [ -d "$cache" ] || mkdir -p "$cache"

    local filename="$(basename "$url")"
    local filepath="$cache/$filename"
    [ -f "$filepath" ] || wget "$url" -P "$cache"
    [ -f "$filepath" ] || exit 2

    echo -e "$filepath"
}

is_param() {
    local item match
    for item in "$@"; do
        if [ -z "$match" ]; then
            match="$item"
        elif [ "$match" = "$item" ]; then
            return 0
        fi
    done
    return 1
}

# check if debian package is installed
check_installed() {
    local item todo
    for item in "$@"; do
        command -v "$item" 2>/dev/null || todo="$todo $item"
    done

    if [ ! -z "$todo" ]; then
        echo -e "this script requires the following packages:${bld}${yel}$todo${rst}"
        exit 1
    fi
}

print_hdr() {
    local msg="$1"
    echo -e "\n${h1}$msg...${rst}"
}

print_err() {
    local msg="$1"
    echo -e "\n${bld}${yel}error: $msg${rst}\n" >&2
}

rst='\033[m'
bld='\033[1m'
red='\033[31m'
grn='\033[32m'
yel='\033[33m'
blu='\033[34m'
mag='\033[35m'
cya='\033[36m'
h1="${blu}==>${rst} ${bld}"

# require linux
uname_s=$(uname -s)
if [ "$uname_s" != 'Linux' ]; then
    print_err "this project requires a Linux system, but '$uname_s' was detected"
    exit 1
fi

# require arm64
uname_m=$(uname -m)
if [ "$uname_m" != 'aarch64' ] && ! command -v qemu-aarch64-static >/dev/null 2>&1; then
    print_err "This project requires an ARM64 architecture, but '$uname_m' was detected"
    exit 1
fi

cd "$(dirname "$(realpath "$0")")"
#check_mount_only "$@"

main "$@"

