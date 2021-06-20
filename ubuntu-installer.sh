#!/bin/bash

function main {

  # set default values and configuration
  HOME="/tmp"
  SELF_PATH="$(readlink -f "$0")"
  SELF_NAME="$(basename "$SELF_PATH")"
  NAME_REGEX='^[a-z][-a-z0-9]*$'
  EXTRA_GROUPS='adm audio cdrom dialout dip floppy libvirt lpadmin plugdev sudo users video wireshark'
  SHOW_HELP=false
  SHELL_LOGIN=false
  USE_EFI=false

  # parse arguments
  OPTIONS_PARSED=$(getopt \
    --options 'hleu:n:c:m:b:x:y:z:' \
    --longoptions 'help,login,efi,username:,hostname:,codename:,mirror:,bundles:,dev-root:,dev-home:,dev-boot:' \
    --name "$SELF_NAME" \
    -- "$@"
  )

  # replace arguments
  eval set -- "$OPTIONS_PARSED"

  # apply arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        SHOW_HELP=true
        shift 1
        ;;
      -l|--login)
        SHELL_LOGIN=true
        shift 1
        ;;
      -e|--efi)
        USE_EFI=true
        shift 1
        ;;
      -u|--username)
        USERNAME_NEW="$2"
        shift 2
        ;;
      -n|--hostname)
        HOSTNAME_NEW="$2"
        shift 2
        ;;
      -c|--codename)
        CODENAME="$2"
        shift 2
        ;;
      -m|--mirror)
        MIRROR="$2"
        shift 2
        ;;
      -b|--bundles)
        BUNDLES="$2"
        shift 2
        ;;
      -x|--dev-root)
        DEV_ROOT="$2"
        shift 2
        ;;
      -y|--dev-home)
        DEV_HOME="$2"
        shift 2
        ;;
      -z|--dev-boot)
        DEV_BOOT="$2"
        shift 2
        ;;
      --)
        shift 1
        break
        ;;
      *)
        break
        ;;
    esac
  done

  # either print the help text or process task
  if "$SHOW_HELP"; then

    # show help text
    show_help

  else

    # check if there is a unassigned argument to interpret it as task
    if [[ $# -eq 0 ]]; then

      echo "$SELF_NAME: require a task to continue" >&2
      exit 1

    fi

    # assign the task
    local TASK="$1"
    shift 1

    # check if there is no unassigned argument left
    if [[ $# -ne 0 ]]; then

      echo "$SELF_NAME: cannot handle unassigned arguments: $*" >&2
      exit 1

    fi

    # select task
    case "$TASK" in
      install-script)
        task_install_script
        ;;
      install-desktop-helpers)
        task_install_desktop_helpers
        ;;
      update)
        task_update
        ;;
      create-user)
        task_create_user
        ;;
      modify-user)
        task_modify_user
        ;;
      manage-package-sources)
        task_manage_package_sources
        ;;
      install-base)
        task_install_base
        ;;
      install-system)
        task_install_system
        ;;
      install-container-image)
        task_install_container_image
        ;;
      *)
        echo "$SELF_NAME: require a valid task" >&2
        exit 1
        ;;
    esac

  fi
}

function check_root_privileges {

  if [[ $EUID -ne 0 ]]; then

    echo "$SELF_NAME: require root privileges" >&2
    exit 1

  fi
}

function check_username {

  if [[ -z "$USERNAME_NEW" ]] || ! echo "$USERNAME_NEW" | grep -qE "$NAME_REGEX"; then

    echo "$SELF_NAME: require valid username" >&2
    exit 1

  fi
}

function check_username_exists {

  if getent passwd "$USERNAME_NEW" > /dev/null; then

    if ! "$1"; then

      echo "$SELF_NAME: the username has already been taken" >&2
      exit 1

    fi

  else

    if "$1"; then

      echo "$SELF_NAME: the username does not exist" >&2
      exit 1

    fi

  fi
}

function check_codename {

  if [[ -z "$CODENAME" ]] || ! echo "$CODENAME" | grep -qE '^[a-z]*$'; then

    echo "$SELF_NAME: require valid Ubuntu codename" >&2
    exit 1

  fi
}

function check_software_bundle_names {

  for i in "${!BARRAY[@]}"; do

    if [[ ${BARRAY[$i]} != 'virt' ]] && \
        [[ ${BARRAY[$i]} != 'dev' ]] && \
        [[ ${BARRAY[$i]} != 'desktop' ]] && \
        [[ ${BARRAY[$i]} != 'laptop' ]] && \
        [[ ${BARRAY[$i]} != 'web' ]] && \
        [[ ${BARRAY[$i]} != 'x86' ]]; then

      echo "$SELF_NAME: require valid bundle names [virt, dev, desktop, laptop, web, x86]" >&2
      exit 1

    fi

  done
}

function check_mounting {

  if [[ -z "$DEV_ROOT" ]] || [[ ! -b "$DEV_ROOT" ]] || mount | grep -q "$DEV_ROOT"; then

    echo "$SELF_NAME: require unmounted device file for /" >&2
    exit 1

  fi

  if [[ -z "$DEV_HOME" ]] || [[ ! -b "$DEV_HOME" ]]; then

    echo "$SELF_NAME: require device file for /home" >&2
    exit 1

  fi
}

function set_bundle_array {

  # create bundle array
  if [[ -z "$BUNDLES" ]]; then

    declare -a BARRAY

  else

    readarray -td ',' BARRAY <<< "$BUNDLES"
    for i in "${!BARRAY[@]}"; do BARRAY[$i]="$(echo "${BARRAY[$i]}" | tr -d '[:space:]')"; done

  fi
}

function set_username_default {

  # use name of current user by default
  if [[ -z "$USERNAME_NEW" ]]; then

    USERNAME_NEW="$(get_username)"

  fi

  # make sure the username is different to root
  if [[ $USERNAME_NEW == "root" ]]; then

    echo "$SELF_NAME: require username different to root" >&2
    exit 1

  fi
}

function set_hostname_default {

  # use current hostname by default
  if [[ -z "$HOSTNAME_NEW" ]]; then

    HOSTNAME_NEW="$HOSTNAME"

  fi
}

function set_mirror_default {

  # use mirror list by default
  if [[ -z "$MIRROR" ]]; then

    MIRROR='mirror://mirrors.ubuntu.com/mirrors.txt'

  fi
}

function set_boot_dev_default {

  if "$USE_EFI"; then

    # use mounted boot partition by default
    if [[ -z "$DEV_BOOT" ]]; then

      DEV_BOOT="$(cat /proc/mounts | grep -E /boot/efi | cut -d ' ' -f 1)"

    fi

  fi
}

function task_install_script {

  # verify arguments
  check_root_privileges

  local TEMPDIR="$(mktemp -d)"
  local BINDIR='/usr/local/sbin'

  git clone 'https://github.com/brettaufheber/ubuntu-installer.git' "$TEMPDIR"

  cp -v "$TEMPDIR/ubuntu-installer.sh" "$BINDIR"
  chmod a+x "$BINDIR/ubuntu-installer.sh"

  rm -rf "$TEMPDIR"
}

function task_install_desktop_helpers {

  # verify arguments
  check_root_privileges

  local TEMPDIR="$(mktemp -d)"
  local BINDIR='/usr/local/sbin'

  git clone 'https://github.com/brettaufheber/ubuntu-installer.git' "$TEMPDIR"

  for i in "$TEMPDIR/desktop-helpers"/*; do

    f="$(basename "$i")"

    cp -v "$i" "$BINDIR"
    chmod a+x "$BINDIR/$f"

  done

  rm -rf "$TEMPDIR"
}

function task_update {

  # verify arguments
  set_bundle_array
  check_root_privileges
  check_software_bundle_names

  # update via APT package manager
  apt-get update
  apt-get -y dist-upgrade
  apt-get -y autoremove --purge

  # update via Snappy package manager
  snap refresh

  # do this only for desktop environments
  if [[ ${BARRAY[*]} =~ 'desktop' ]]; then

    # update via Flatpak package manager
    flatpak -y update

    # update helper scripts
    ubuntu-installer.sh install-desktop-helpers

  fi
}

function task_create_user {

  # verify arguments
  set_username_default
  check_root_privileges
  check_username
  check_username_exists false

  # create user and home-directory if not exist
  adduser --add_extra_groups "$USERNAME_NEW"
}

function task_modify_user {

  # verify arguments
  set_username_default
  check_root_privileges
  check_username
  check_username_exists true

  # create home-directory if not exist
  mkhomedir_helper "$USERNAME_NEW"

  # add user to extra groups
  for i in $EXTRA_GROUPS; do

    if grep -qE "^$i:" /etc/group; then

      usermod -aG "$i" "$USERNAME_NEW"

    fi

  done
}

function task_manage_package_sources {

  # verify arguments
  set_mirror_default
  check_root_privileges

  # set variables
  local SRCLIST='/etc/apt/sources.list.d'
  local COMPONENTS='main universe multiverse restricted'

  # set OS variables
  . /etc/os-release

  # add package sources
  add-apt-repository -s "deb $MIRROR $UBUNTU_CODENAME $COMPONENTS"
  add-apt-repository -s "deb $MIRROR $UBUNTU_CODENAME-updates $COMPONENTS"
  add-apt-repository -s "deb $MIRROR $UBUNTU_CODENAME-security $COMPONENTS"
  add-apt-repository -s "deb $MIRROR $UBUNTU_CODENAME-backports $COMPONENTS"

  # add package sources for sbt
  ## uid: sbt build tool <scalasbt@gmail.com>
  ## fingerprint: 2EE0EA64E40A89B84B2DF73499E82A75642AC823
  wget -qO - 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x99E82A75642AC823' \
    | sed -n '/-----BEGIN PGP PUBLIC KEY BLOCK-----/,/-----END PGP PUBLIC KEY BLOCK-----/p' \
    | apt-key add -
  echo 'deb https://dl.bintray.com/sbt/debian /' > "$SRCLIST/sbt.list"

  # add package sources for chrome browser
  wget -qO - 'https://dl-ssl.google.com/linux/linux_signing_key.pub' \
    | apt-key add -
  echo 'deb https://dl.google.com/linux/chrome/deb/ stable main' > "$SRCLIST/google-chrome.list"

  # update package lists
  apt-get update
}

function task_install_base {

  # verify arguments
  set_bundle_array
  check_root_privileges
  check_software_bundle_names

  # disable interactive interfaces
  export DEBIAN_FRONTEND=noninteractive

  # update installed software
  apt-get -y dist-upgrade
  apt-get -y autoremove --purge

  # install main packages
  apt-get -y install ubuntu-server ubuntu-standard
  apt-get -y install lxc debootstrap bridge-utils
  apt-get -y install software-properties-common
  apt-get -y install debconf-utils
  apt-get -y install aptitude

  # set default values for packages
  echo wireshark-common wireshark-common/install-setuid select true | debconf-set-selections
  echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | debconf-set-selections

  # install version control system
  apt-get -y install git

  # install text editors and query tools
  apt-get -y install vim
  apt-get -y install emacs-nox
  apt-get -y install nano
  apt-get -y install jq

  # install network tooling
  apt-get -y install net-tools

  # install archiving and compression tools
  apt-get -y install tar gzip bzip2 zip unzip p7zip

  # install SSH support
  apt-get -y install openssh-server openssh-client

  # install SSL support
  apt-get -y install openssl

  # install support of snap packages
  apt-get -y install snapd

  # install OpenJDK JRE (headless)
  apt-get -y install openjdk-11-jre-headless

  # install everything else needed by a simple general purpose system
  aptitude -y install ~pstandard ~pimportant ~prequired

  # virtualization software
  if [[ ${BARRAY[*]} =~ 'virt' ]]; then

    # install machine emulator and virtualizer with tooling
    apt-get -y install qemu qemu-kvm
    apt-get -y install virtinst libvirt-daemon-system

  fi

  # development software
  if [[ ${BARRAY[*]} =~ 'dev' ]]; then

    # install support for Assembly/C/C++
    apt-get -y install build-essential
    apt-get -y install clang lldb lld llvm
    apt-get -y install cmake
    apt-get -y install libboost-all-dev
    apt-get -y install qt5-default qttools5-dev-tools qttools5-dev
    apt-get -y install libgtkmm-3.0-dev libgtkmm-2.4-dev

    # install support for Ada
    apt-get -y install gnat

    # install support for Objective-C
    apt-get -y install gobjc

    # install support for Perl
    apt-get -y install perl
    apt-get -y install libgtk3-perl libgtk2-perl

    # install support for PHP
    apt-get -y install php-cli php-fpm
    apt-get -y install php-pear

    # install support for Haskell
    apt-get -y install ghc

    # install support for Python
    apt-get -y install python3
    apt-get -y install python3-pip
    apt-get -y install python3-pyqt5 pyqt5-dev-tools
    apt-get -y install python3-gi
    apt-get -y install python3-numpy python3-scipy python3-matplotlib

    # install support for Ruby
    apt-get -y install ruby-full
    apt-get -y install rubygems

    # install support for JavaScript (Node.js environment)
    apt-get -y install nodejs
    apt-get -y install npm

    # install support for C# and Visual Basic (Mono environment)
    apt-get -y install mono-complete mono-mcs mono-vbnc

    # install support for Go
    apt-get -y install golang

    # install support for Rust
    apt-get -y install rustc
    apt-get -y install cargo

    # install support for Java, Scala and other JVM languages
    apt-get -y install openjdk-11-jdk
    apt-get -y install ant
    apt-get -y install maven
    apt-get -y install gradle
    apt-get -y install sbt

    # install network diagnostic tools
    apt-get -y install nmap
    apt-get -y install tshark

  fi

  if [[ ${BARRAY[*]} =~ 'dev' ]] && [[ ${BARRAY[*]} =~ 'x86' ]]; then

    # install x86 specific tools and libraries for Assembly/C/C++
    apt-get -y install gcc-multilib g++-multilib
    apt-get -y install nasm

  fi

  # minimal desktop
  if [[ ${BARRAY[*]} =~ 'desktop' ]]; then

    # get current system language
    . /etc/default/locale
    SYSLANG="$(echo "$LANG" | grep -oE '^([a-zA-Z]+)' | sed -r 's/^(C|POSIX)$/en/')"
    SYSLANG="${SYSLANG:-'en'}"

    # install GTK+ libraries
    apt-get -y install libgtk-3-dev libgtk2.0-dev

    # install GNOME desktop
    apt-get -y install gnome-session
    apt-get -y install gucharmap
    apt-get -y install gnome-core
    apt-get -y install gnome-contacts
    apt-get -y install gnome-calendar
    apt-get -y install gnome-software-plugin-snap
    apt-get -y install gnome-software-plugin-flatpak flatpak
    apt-get -y install language-selector-gnome
    apt-get -y install ubuntu-restricted-extras
    apt-get -y install materia-gtk-theme
    apt-get -y install dconf-cli dconf-editor
    apt-get -y install gedit ghex

    # install some plugins for VPN support
    apt-get -y install network-manager-pptp network-manager-pptp-gnome
    apt-get -y install network-manager-l2tp network-manager-l2tp-gnome
    apt-get -y install network-manager-openvpn network-manager-openvpn-gnome
    apt-get -y install network-manager-openconnect network-manager-openconnect-gnome
    apt-get -y install network-manager-vpnc network-manager-vpnc-gnome
    apt-get -y install network-manager-strongswan

    # install scanner and printer support
    apt-get -y install simple-scan
    apt-get -y install cups cups-client cups-bsd
    apt-get -y install system-config-printer-gnome

    # install font files
    apt-get -y install fonts-open-sans
    apt-get -y install fonts-dejavu
    apt-get -y install fonts-ubuntu fonts-ubuntu-console

    # install OpenJDK JRE
    apt-get -y install openjdk-11-jre

    # install audio recorder
    apt-get -y install audacity

    # install webcam tooling
    apt-get -y install guvcview

    # install web browsers
    apt-get -y install firefox
    apt-get -y install google-chrome-stable
    apt-get -y install chrome-gnome-shell

    # install language pack
    apt-get -y install "language-pack-gnome-$SYSLANG"

    # set GDM theme
    update-alternatives --install \
      /usr/share/gnome-shell/theme/gdm3.css gdm3.css /usr/share/themes/Materia-dark/gnome-shell/gnome-shell.css 42
    update-alternatives --set \
      gdm3.css /usr/share/themes/Materia-dark/gnome-shell/gnome-shell.css

  fi

  # minimal desktop with virtualization software
  if [[ ${BARRAY[*]} =~ 'desktop' ]] && [[ ${BARRAY[*]} =~ 'virt' ]]; then

    # graphical VM manager
    apt-get -y install virt-manager

  fi

  # minimal desktop with development software
  if [[ ${BARRAY[*]} =~ 'desktop' ]] && [[ ${BARRAY[*]} =~ 'dev' ]]; then

    # install network packet analyzer
    apt-get -y install wireshark

  fi

  # power saving tools
  if [[ ${BARRAY[*]} =~ 'laptop' ]]; then

    # install tool to collect power-usage metrics
    apt-get -y install powertop

    # install advanced power management
    apt-get -y install tlp tlp-rdw

  fi

  # web server and web proxy
  if [[ ${BARRAY[*]} =~ 'web' ]]; then

    # install web server
    apt-get -y install nginx

    # install high availability TCP/HTTP load balancer
    apt-get -y install haproxy

  fi
}

function task_install_system {

  # verify arguments
  set_bundle_array
  set_username_default
  set_hostname_default
  set_mirror_default
  set_boot_dev_default
  check_root_privileges
  check_username
  check_codename
  check_mounting
  check_software_bundle_names

  # format $DEV_ROOT
  mkfs.ext4 "$DEV_ROOT"

  # mount "/" and "/home"
  mounting_step_1

  # execute debootstrap
  install_minimal_system

  # configuration before starting chroot
  configure_hosts
  configure_fstab
  configure_vim
  configure_users
  configure_network

  # mount OS resources into chroot environment
  mounting_step_2

  # configure packages
  configure_packages

  # install requirements, kernel and bootloader
  install_host_requirements

  # manage package sources
  chroot "$CHROOT" "$SELF_NAME" manage-package-sources -m "$MIRROR"

  # install software
  chroot "$CHROOT" "$SELF_NAME" install-base -b "$BUNDLES"

  # do some modifications for desktop environments
  configure_desktop

  # remove retrieved package files
  chroot "$CHROOT" apt-get clean

  # create user
  chroot "$CHROOT" "$SELF_NAME" create-user -u "$USERNAME_NEW"

  # login to shell for diagnostic purposes
  if "$SHELL_LOGIN"; then

    echo "$SELF_NAME: You are now logged in to the chroot environment for diagnostic purposes. Press Ctrl-D to escape."
    chroot "$CHROOT" /bin/bash

  fi

  # unmount everything
  unmounting_step_2
  unmounting_step_1

  # show that we are done here
  echo "$SELF_NAME: done."
}

function task_install_container_image {

  # verify arguments
  set_bundle_array
  set_username_default
  set_mirror_default
  check_root_privileges
  check_codename
  check_software_bundle_names

  # create temporary directory
  local TEMPDIR="$(mktemp -d)"

  # set root directory
  CHROOT="$TEMPDIR/rootfs"

  # create root directory
  mkdir -p "$CHROOT"

  # execute debootstrap
  install_minimal_system

  # configuration before starting chroot
  configure_vim
  configure_users

  # mount OS resources into chroot environment
  mounting_step_2

  # configure packages
  configure_packages

  # install requirements
  install_container_requirements

  # manage package sources
  chroot "$CHROOT" "$SELF_NAME" manage-package-sources -m "$MIRROR"

  # install software
  chroot "$CHROOT" "$SELF_NAME" install-base -b "$BUNDLES"

  # do some modifications for desktop environments
  configure_desktop

  # remove retrieved package files
  chroot "$CHROOT" apt-get clean

  # unmount everything
  unmounting_step_2

  # define image name
  local IMAGE_RELEASE="$(cat '/proc/sys/kernel/random/uuid' | tr -dc '[:alnum:]')"
  local IMAGE_NAME="ubuntu-$CODENAME-$IMAGE_RELEASE"

  # create metadata file
  echo "architecture: x86_64" > "$TEMPDIR/metadata.yaml"
  echo "creation_date: $(date +%s)" >> "$TEMPDIR/metadata.yaml"
  echo "properties:" >> "$TEMPDIR/metadata.yaml"
  echo "  architecture: x86_64" >> "$TEMPDIR/metadata.yaml"
  echo "  description: Ubuntu $CODENAME with extended tooling" >> "$TEMPDIR/metadata.yaml"
  echo "  os: ubuntu" >> "$TEMPDIR/metadata.yaml"
  echo "  release: $CODENAME $IMAGE_RELEASE" >> "$TEMPDIR/metadata.yaml"
  echo "templates:" >> "$TEMPDIR/metadata.yaml"
  echo "  /etc/hosts:" >> "$TEMPDIR/metadata.yaml"
  echo "    when:" >> "$TEMPDIR/metadata.yaml"
  echo "      - create" >> "$TEMPDIR/metadata.yaml"
  echo "      - copy" >> "$TEMPDIR/metadata.yaml"
  echo "      - rename" >> "$TEMPDIR/metadata.yaml"
  echo "    template: hosts.tpl" >> "$TEMPDIR/metadata.yaml"
  echo "  /etc/hostname:" >> "$TEMPDIR/metadata.yaml"
  echo "    when:" >> "$TEMPDIR/metadata.yaml"
  echo "      - create" >> "$TEMPDIR/metadata.yaml"
  echo "      - copy" >> "$TEMPDIR/metadata.yaml"
  echo "      - rename" >> "$TEMPDIR/metadata.yaml"
  echo "    template: hostname.tpl" >> "$TEMPDIR/metadata.yaml"

  # create template directory
  mkdir "$TEMPDIR/templates"

  # create templates (use container name as hostname)
  configure_hosts_template "{{ container.name }}" "$TEMPDIR/templates/hostname.tpl" "$TEMPDIR/templates/hosts.tpl"

  # create tarballs for rootfs and metadata
  tar -czf "$TEMPDIR/rootfs.tar.gz" -C "$CHROOT" .
  tar -czf "$TEMPDIR/metadata.tar.gz" -C "$TEMPDIR" 'metadata.yaml' 'templates'

  # install image
  lxc image import "$TEMPDIR/metadata.tar.gz" "$TEMPDIR/rootfs.tar.gz" --alias "$IMAGE_NAME"

  # remove temporary directory
  rm -rf "$TEMPDIR"

  # show that we are done here
  echo "$SELF_NAME: image $IMAGE_NAME imported"
}

function configure_hosts {

  # configure hosts with default arguments
  configure_hosts_template "$HOSTNAME_NEW" "$CHROOT/etc/hostname" "$CHROOT/etc/hosts"
}

function configure_hosts_template {

  # edit /etc/hostname
  echo "$1" > "$2"

  # edit /etc/hosts
  echo "127.0.0.1   localhost" > "$3"
  echo "127.0.1.1   $1" >> "$3"
  echo "" >> "$3"
  echo "# The following lines are desirable for IPv6 capable hosts" >> "$3"
  echo "::1         ip6-localhost ip6-loopback" >> "$3"
  echo "fe00::0     ip6-localnet" >> "$3"
  echo "ff00::0     ip6-mcastprefix" >> "$3"
  echo "ff02::1     ip6-allnodes" >> "$3"
  echo "ff02::2     ip6-allrouters" >> "$3"
  echo "ff02::3     ip6-allhosts" >> "$3"
}

function configure_fstab {

  # set path /etc/fstab
  local FILE="$CHROOT/etc/fstab"

  # get UUID of each partition
  local UUID_ROOT="$(blkid -s UUID -o value "$DEV_ROOT")"
  local UUID_HOME="$(blkid -s UUID -o value "$DEV_HOME")"

  if "$USE_EFI"; then

    local UUID_UEFI="$(blkid -s UUID -o value "$DEV_BOOT")"
    local FILE_UEFI="$FILE"

  else

    local FILE_UEFI="/dev/null"

  fi

  # edit /etc/fstab
  echo '# /etc/fstab' > "$FILE"
  echo '# <file system>     <mount point>     <type>     <options>                        <dump> <pass>' >> "$FILE"
  echo "UUID=$UUID_ROOT     /                 ext4       defaults,errors=remount-ro       0      1" >> "$FILE"
  echo "UUID=$UUID_UEFI     /boot/efi         vfat       defaults                         0      2" >> "$FILE_UEFI"
  echo "UUID=$UUID_HOME     /home             ext4       defaults                         0      2" >> "$FILE"
  echo "proc                /proc             proc       defaults                         0      0" >> "$FILE"
  echo "sys                 /sys              sysfs      defaults                         0      0" >> "$FILE"
  echo "tmpfs               /tmp              tmpfs      defaults,size=40%                0      0" >> "$FILE"
}

function configure_vim {

  # set path /etc/vim/vimrc
  local FILE="$CHROOT/etc/vim/vimrc"

  # edit /etc/vim/vimrc
  echo '' >> "$FILE"
  echo 'filetype plugin indent on' >> "$FILE"
  echo 'syntax on' >> "$FILE"
  echo 'set nocp' >> "$FILE"
  echo 'set background=light' >> "$FILE"
  echo 'set tabstop=4' >> "$FILE"
  echo 'set shiftwidth=4' >> "$FILE"
  echo 'set expandtab' >> "$FILE"
}

function configure_users {

  # set path /etc/adduser.conf
  local FILE="$CHROOT/etc/adduser.conf"

  # edit /etc/adduser.conf
  sed -ie 's/^#EXTRA_GROUPS=.*/EXTRA_GROUPS="'"$EXTRA_GROUPS"'"/' "$FILE"
  sed -ie 's/^#NAME_REGEX=.*/NAME_REGEX="'"$NAME_REGEX"'"/' "$FILE"
}

function configure_network {

  # set HTTP proxy
  if [[ -n "$http_proxy" ]]; then

    echo "http_proxy=$http_proxy" >> "$CHROOT/etc/environment"
    echo "HTTP_PROXY=$http_proxy" >> "$CHROOT/etc/environment"
    echo "Acquire::http::proxy \"$http_proxy\";" >> "$CHROOT/etc/apt/apt.conf"

  fi

  # set HTTPS proxy
  if [[ -n "$https_proxy" ]]; then

    echo "https_proxy=$https_proxy" >> "$CHROOT/etc/environment"
    echo "HTTPS_PROXY=$https_proxy" >> "$CHROOT/etc/environment"
    echo "Acquire::https::proxy \"$https_proxy\";" >> "$CHROOT/etc/apt/apt.conf"

  fi

  # set FTP proxy
  if [[ -n "$ftp_proxy" ]]; then

    echo "ftp_proxy=$ftp_proxy" >> "$CHROOT/etc/environment"
    echo "FTP_PROXY=$ftp_proxy" >> "$CHROOT/etc/environment"
    echo "Acquire::ftp::proxy \"$ftp_proxy\";" >> "$CHROOT/etc/apt/apt.conf"

  fi

  # set all socks proxy
  if [[ -n "$all_proxy" ]]; then

    echo "all_proxy=$all_proxy" >> "$CHROOT/etc/environment"
    echo "ALL_PROXY=$all_proxy" >> "$CHROOT/etc/environment"

  fi

  # set ignore-hosts
  if [[ -n "$no_proxy" ]]; then

    echo "no_proxy=$no_proxy" >> "$CHROOT/etc/environment"
    echo "NO_PROXY=$no_proxy" >> "$CHROOT/etc/environment"

  fi

  # copy DNS settings
  if [[ -f '/etc/systemd/resolved.conf' ]]; then

    cp -f '/etc/systemd/resolved.conf' "$CHROOT/etc/systemd/resolved.conf"

  fi

  # copy connection settings (system without network-manager)
  if [[ -d '/etc/netplan' ]]; then

    mkdir -p "$CHROOT/etc/netplan"
    cp -rf '/etc/netplan/.' "$CHROOT/etc/netplan"

  fi

  # copy connection settings (system with network-manager)
  if [[ -d '/etc/NetworkManager/system-connections' ]]; then

    mkdir -p "$CHROOT/etc/NetworkManager/system-connections"
    cp -rf '/etc/NetworkManager/system-connections/.' "$CHROOT/etc/NetworkManager/system-connections"

  fi

  # https://bugs.launchpad.net/ubuntu/+source/network-manager/+bug/1638842
  if [[ ${BARRAY[*]} =~ 'desktop' ]]; then

    mkdir -p "$CHROOT/etc/NetworkManager/conf.d"
    touch "$CHROOT/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"

  fi
}

function configure_packages {

  # temporary file for this installation step
  local TEMPFILE="$(mktemp)"

  # write installation script
  echo '#!/bin/bash' > "$TEMPFILE"
  cat >> "$TEMPFILE" << 'EOF'

# set default locale
locale-gen en_US.UTF-8 en_GB.UTF-8 de_DE.UTF-8
update-locale LANG=C.UTF-8 LC_MESSAGES=POSIX

# configuration by user
dpkg-reconfigure locales
dpkg-reconfigure tzdata
dpkg-reconfigure keyboard-configuration

EOF

  # execute script
  chroot "$CHROOT" /bin/bash "$TEMPFILE"
  rm "$TEMPFILE"
}

function configure_desktop {

  # only apply if desktop bundle is selected
  if [[ ${BARRAY[*]} =~ 'desktop' ]]; then

    # add flatpak remote: flathub
    chroot "$CHROOT" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

    # install helper scripts
    chroot "$CHROOT" "$SELF_NAME" install-desktop-helpers

    # modify default GNOME settings
    install_default_gnome_settings

  fi
}

function install_minimal_system {

  # install minimal system without kernel or bootloader
  debootstrap --arch=amd64 "$CODENAME" "$CHROOT" 'http://archive.ubuntu.com/ubuntu'

  # make this script available
  cp -f "$SELF_PATH" "$CHROOT/usr/local/sbin"
  chmod a+x "$CHROOT/usr/local/sbin/$SELF_NAME"
}

function install_host_requirements {

  # temporary file for this installation step
  local TEMPFILE="$(mktemp)"

  # write installation script
  echo '#!/bin/bash' > "$TEMPFILE"
  echo '' > "$TEMPFILE"
  echo "USE_EFI=$USE_EFI" > "$TEMPFILE"
  cat >> "$TEMPFILE" << 'EOF'

# install main packages
apt-get -y install debootstrap
apt-get -y install software-properties-common

# install Linux kernel and GRUB bootloader
apt-get -y install linux-generic

# install microcode for Intel
if cat /proc/cpuinfo | grep -qE '^model name\s+:\s+Intel'; then

  apt-get -y install intel-microcode

fi

# install microcode for AMD
if cat /proc/cpuinfo | grep -qE '^model name\s+:\s+AMD'; then

  apt-get -y install amd64-microcode

fi

if "$USE_EFI"; then

  apt-get -y install grub-efi
  grub-install --target=x86_64-efi --efi-directory=/boot/efi
  echo 'The boot order must be adjusted manually using the efibootmgr tool.'

fi

# set GRUB_CMDLINE_LINUX_DEFAULT
sed -ie 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet noplymouth"/' /etc/default/grub

# apply grub configuration changes
update-grub

EOF

  # execute script
  chroot "$CHROOT" /bin/bash "$TEMPFILE"
  rm "$TEMPFILE"
}

function install_container_requirements {

  # temporary file for this installation step
  local TEMPFILE="$(mktemp)"

  # write installation script
  echo '#!/bin/bash' > "$TEMPFILE"
  cat >> "$TEMPFILE" << 'EOF'

# install main packages
apt-get -y install debootstrap
apt-get -y install software-properties-common

# install init scripts for cloud instances
apt-get -y install cloud-init

EOF

  # execute script
  chroot "$CHROOT" /bin/bash "$TEMPFILE"
  rm "$TEMPFILE"
}

function install_default_gnome_settings {

  # create configuration directory
  mkdir -p "$CHROOT/etc/dconf/db/site.d/"

  # write default settings
  echo '# changed default settings' > "$CHROOT/etc/dconf/db/site.d/defaults"
  cat >> "$CHROOT/etc/dconf/db/site.d/defaults" << 'EOF'

# set background

[org/gnome/desktop/background]
color-shading-type='solid'

[org/gnome/desktop/background]
picture-options='wallpaper'

[org/gnome/desktop/background]
picture-uri='file:////usr/share/gnome-control-center/pixmaps/noise-texture-light.png'

[org/gnome/desktop/background]
primary-color='#425265'

[org/gnome/desktop/background]
secondary-color='#425265'

[org/gnome/desktop/screensaver]
color-shading-type='solid'

[org/gnome/desktop/screensaver]
picture-options='wallpaper'

[org/gnome/desktop/screensaver]
picture-uri='file:////usr/share/gnome-control-center/pixmaps/noise-texture-light.png'

[org/gnome/desktop/screensaver]
primary-color='#425265'

[org/gnome/desktop/screensaver]
secondary-color='#425265'

# set default theme

[org/gnome/shell]
enabled-extensions=['user-theme@gnome-shell-extensions.gcampax.github.com']

[org/gnome/desktop/interface]
gtk-theme='Materia-light-compact'

[org/gnome/shell/extensions/user-theme]
name='Materia-dark'

# power saving options

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
idle-dim=false

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-battery-type='nothing'

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'

[org/gnome/settings-daemon/plugins/power]
power-button-action='suspend'

# disable event sounds

[org/gnome/desktop/sound]
event-sounds=false

# disable auto mount

[org/gnome/desktop/media-handling]
automount=false

[org/gnome/desktop/media-handling]
automount-open=false

# modify user interface ("dconf watch /" helps to find the keys and values)

[org/gnome/shell]
disable-user-extensions=false

[org/gnome/desktop/wm/preferences]
button-layout='appmenu:minimize,maximize,close'

[org/gnome/desktop/interface]
show-battery-percentage=true

[org/gnome/desktop/interface]
clock-show-weekday=true

[org/gnome/desktop/interface]
clock-show-date=true

[org/gnome/desktop/interface]
clock-show-seconds=false

[org/gnome/desktop/calendar]
show-weekdate=true

[org/gnome/mutter]
dynamic-workspaces=true

EOF

  # change dconf profile
  echo 'user-db:user' >> "$CHROOT/etc/dconf/profile/user"
  echo 'system-db:site' >> "$CHROOT/etc/dconf/profile/user"

  # update dconf inside chroot
  chroot "$CHROOT" dconf update
}

function show_help {

  echo "Usage: $SELF_NAME <task>"
  echo "   ( -u | --username ) <your username>"
  echo "   ( -n | --hostname ) <hostname>"
  echo "   ( -c | --codename ) <Ubuntu codename: bionic|cosmic|...>"
  echo "   ( -m | --mirror   ) <mirror for APT package manager>"
  echo "   ( -b | --bundles  ) <desktop,dev,...>"
  echo "   ( -x | --dev-root ) <block device file for system partition '/'>"
  echo "   ( -y | --dev-home ) <block device file for home partition '/home'>"
  echo ""
  echo "Show this text: $SELF_NAME ( -h | --help )"
  echo ""
  echo "Enter shell after installation: $SELF_NAME ( -l | --login )"
  echo ""
  echo "Tasks:"
  echo "   * install-script: install the newest version of this script"
  echo "   * install-desktop-helpers: install helper scripts for desktops"
  echo "   * update: update the system with all package managers"
  echo "   * create-user: create user with extra groups and home-directory"
  echo "   * modify-user: add extra groups to user and create home-directory"
  echo "   * manage-package-sources: add package sources"
  echo "   * install-base: install bundles and tools for a general purpose system"
  echo "   * install-system: install Ubuntu to block device files"
  echo "   * install-container-image: install a generated LXD/LXC image"
  echo ""
  echo "Software bundles:"
  echo "   * virt: QEMU/KVM with extended tooling"
  echo "   * dev: basic equipment for software developers"
  echo "   * desktop: minimal GNOME desktop"
  echo "   * laptop: power saving tools for mobile devices"
  echo "   * web: server and proxy for web"
  echo "   * x86: architecture specific tools and libraries"
  echo ""
}

function get_username {

  local ORIGIN_USER="$USER"
  local CURRENT_PID=$$
  local CURRENT_USER=$ORIGIN_USER
  local RESULT

  while [[ "$CURRENT_USER" == "root" && $CURRENT_PID > 0 ]]; do

    RESULT=($(ps h -p $CURRENT_PID -o user,ppid))
    CURRENT_USER="${RESULT[0]}"
    CURRENT_PID="${RESULT[1]}"

  done

  getent passwd "$CURRENT_USER" | cut -d : -f 1
}

function mounting_step_1 {

  # modify CLEANUP_MASK
  CLEANUP_MASK=$(( $CLEANUP_MASK | 1 ))

  # set path to mounting point
  CHROOT="/mnt/ubuntu-$(cat '/proc/sys/kernel/random/uuid')"
  CHHOME="$CHROOT/home"

  # mount $DEV_ROOT
  mkdir -p "$CHROOT"
  mount "$DEV_ROOT" "$CHROOT"

  # mount $DEV_HOME
  if mount | grep -q "$DEV_HOME"; then

    local HOME_PATH="$(df "$DEV_HOME" | grep -oE '(/[[:alnum:]]+)+$' | head -1)"

    mkdir -p "$CHHOME"
    mount -o bind "$HOME_PATH" "$CHHOME"

  else

    mkdir -p "$CHHOME"
    mount "$DEV_HOME" "$CHHOME"

  fi
}

function unmounting_step_1 {

  # check whether the step is required or not
  if [[ $(( $CLEANUP_MASK & 1 )) -ne 0 ]]; then

    # unmount home directory and directory root
    umount "$CHHOME"
    umount "$CHROOT"
    rmdir "$CHROOT"

  fi
}

function mounting_step_2 {

  # modify CLEANUP_MASK
  CLEANUP_MASK=$(( $CLEANUP_MASK | 2 ))

  # flush the cache
  sync

  # mount resources needed for chroot
  mount -t proc /proc "$CHROOT/proc"
  mount -t sysfs /sys "$CHROOT/sys"
  mount -o bind /dev/ "$CHROOT/dev"
  mount -o bind /dev/pts "$CHROOT/dev/pts"
  mount -o bind /run "$CHROOT/run"
  mount -o bind /tmp "$CHROOT/tmp"

  if "$USE_EFI"; then

    # mount $DEV_BOOT
    if mount | grep -q "$DEV_BOOT"; then

      local BOOT_PATH="$(df "$DEV_BOOT" | grep -oE '(/[[:alnum:]]+)+$' | head -1)"

      mkdir -p "$CHROOT/boot/efi"
      mount -o bind "$BOOT_PATH" "$CHROOT/boot/efi"

    else

      mkdir -p "$CHROOT/boot/efi"
      mount "$DEV_BOOT" "$CHROOT/boot/efi"

    fi

  fi
}

function unmounting_step_2 {

  # check whether the step is required or not
  if [[ $(( $CLEANUP_MASK & 2 )) -ne 0 ]]; then

    # flush the cache
    sync

    # unmount resources
    umount -l "$CHROOT/tmp"
    umount -l "$CHROOT/run"
    umount -l "$CHROOT/dev/pts"
    umount -l "$CHROOT/dev"
    umount -l "$CHROOT/sys"
    umount -l "$CHROOT/proc"

    if "$USE_EFI"; then

      umount -l "$CHROOT/boot/efi"

    fi

  fi
}

function error_trap {

  # cleanup
  unmounting_step_2
  unmounting_step_1

  echo "$SELF_NAME: script stopped caused by unexpected return code $1 at line $2" >&2
  exit 3
}

function interrupt_trap {

  # cleanup
  unmounting_step_2
  unmounting_step_1

  echo "$SELF_NAME: script interrupted by signal" >&2
  exit 2
}

set -eEo pipefail
CLEANUP_MASK=0
trap 'RC=$?; error_trap "$RC" "$LINENO"' ERR
trap 'interrupt_trap' INT
main "$@"
exit 0
