
set dotenv-load
set dotenv-filename := x"${GITHUB_ENV:-.env.build}"

VERSION := env_var_or_default("VERSION", "24.10.2")
SOURCE_URL := env_var_or_default("SOURCE_URL", "https://github.com/openwrt/openwrt.git")
SOURCE_BRANCH := env_var_or_default("SOURCE_BRANCH", "v" + VERSION)
CLONE_DEPTH := env_var_or_default("CLONE_DEPTH", "1")
WORKSPACE := env_var_or_default("WORKSPACE", justfile_directory())
BUILD_DIR := env_var_or_default("BUILD_DIR", WORKSPACE / "build")
OUTPUT_DIR := env_var_or_default("OUTPUT_DIR", WORKSPACE / "output")
OVERLAY_DIR := env_var_or_default("OVERLAY_DIR", WORKSPACE / "overlay")
CONFIG_FILE := env_var_or_default("CONFIG_FILE", ".config")
DEVICE_TARGET := env_var_or_default("DEVICE_TARGET", "x86")
DEVICE_SUBTARGET := env_var_or_default("DEVICE_SUBTARGET", "64")
TOOLCHAIN_IMAGE := env_var_or_default("TOOLCHAIN_IMAGE", "toolchain-" + DEVICE_TARGET + "_" + DEVICE_SUBTARGET + ".img")
ENV_FILE := env_var_or_default("GITHUB_ENV", WORKSPACE / ".env.build")


# Setup Environment
setup:
  sudo -E apt -qq -y upgrade
  sudo -E apt -y install fuse3
  sudo -E apt -y install squashfs-tools locales
  sudo -E apt -y install build-essential clang flex bison g++ gawk gcc-multilib gettext git libncurses5-dev libssl-dev python3 rsync zip unzip zlib1g-dev file wget
  sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  sudo sed -i "/$LANG/s/^# //g" /etc/locale.gen
  sudo locale
  sudo -E apt -y autoremove --purge
  sudo -E apt -y clean

# # Checkout Source Code
checkout:
  mkdir {{BUILD_DIR}}
  git clone --depth {{CLONE_DEPTH}} -b {{SOURCE_BRANCH}} {{SOURCE_URL}} {{BUILD_DIR}}

# Generate Toolchain Config
[group: 'Toolchain']
config:
  [ ! -f {{CONFIG_FILE}} ] && just download-config || true
  cp {{CONFIG_FILE}} {{BUILD_DIR}}/.config
  cd {{BUILD_DIR}} && make defconfig > /dev/null 2>&1

# Generate Variables
gen-env:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{BUILD_DIR}} && rm -f {{ENV_FILE}}

  export CURRENT_HASH=$(git log --pretty=tformat:"%H" -n1 tools toolchain)
  echo "CURRENT_HASH=$CURRENT_HASH" >> {{ENV_FILE}}

  export DEVICE_TARGET=$(cat .config | grep CONFIG_TARGET_BOARD | awk -F '"' '{print $2}')
  echo "DEVICE_TARGET=$DEVICE_TARGET" >> {{ENV_FILE}}

  export DEVICE_SUBTARGET=$(cat .config | grep CONFIG_TARGET_SUBTARGET | awk -F '"' '{print $2}')
  echo "DEVICE_SUBTARGET=$DEVICE_SUBTARGET" >> {{ENV_FILE}}

  export DEVICE_PLATFORM=$(cat .config | grep CONFIG_TARGET_ARCH_PACKAGES | awk -F '"' '{print $2}')
  echo "DEVICE_PLATFORM=$DEVICE_PLATFORM" >> {{ENV_FILE}}

  export TOOLCHAIN_IMAGE="toolchain-${DEVICE_TARGET}_${DEVICE_SUBTARGET}.img"
  echo "TOOLCHAIN_IMAGE=$TOOLCHAIN_IMAGE" >> {{ENV_FILE}}

  # FUSE=$(command -v squashfuse > /dev/null 2>&1 && command -v fuse-overlayfs > /dev/null 2>&1)
  # echo "FUSE=$FUSE" >> {{ENV_FILE}}

  export BUILD_DATE=$(date +"%Y-%m-%d")
  echo "BUILD_DATE=$BUILD_DATE" >> {{ENV_FILE}}

  cat {{ENV_FILE}}

# Compile Tools
[group: 'Toolchain']
compile-tool:
  echo "$(nproc) threads compile tools"
  cd {{BUILD_DIR}} && make tools/compile -j$(nproc)


# Compile Toolchain
[group: 'Toolchain']
compile-toolchain:
  echo "$(nproc) threads compile toolchain"
  cd {{BUILD_DIR}} && make toolchain/compile -j$(nproc)
  cd {{BUILD_DIR}} && rm -rf .config* dl bin

# Generate Toolchain Image
[group: 'Toolchain']
generate-toolchain-image:
  mkdir -p {{OUTPUT_DIR}}
  cd {{WORKSPACE}} && mksquashfs {{BUILD_DIR}} {{OUTPUT_DIR}}/{{TOOLCHAIN_IMAGE}} -force-gid 1001 -force-uid 1001 -comp zstd
  echo $CURRENT_HASH > {{OUTPUT_DIR}}/{{TOOLCHAIN_IMAGE}}.hash

[group: 'Toolchain']
make-toolchain:
  just compile-tool
  just compile-toolchain

[group: 'Firmware']
custom-feeds:
  echo "Custom feeds configuration"

# Install Feeds
[group: 'Firmware']
install-feeds:
  cd {{BUILD_DIR}} && ./scripts/feeds clean
  cd {{BUILD_DIR}} && ./scripts/feeds update -a
  cd {{BUILD_DIR}} && ./scripts/feeds install -a

# Custom Configuration
[group: 'Firmware']
custom-config:
  [ ! -f {{CONFIG_FILE}} ] && just download-config || true
  cp {{CONFIG_FILE}} {{BUILD_DIR}}/.config
  # do some custom configuration adjustments if needed
  cd {{BUILD_DIR}} && make defconfig

# Download Packages
[group: 'Firmware']
download-packages:
  cd {{BUILD_DIR}} && make download -j$(nproc)
  df -hT

# Compile Packages
[group: 'Firmware']
compile-packages:
  echo "$(nproc) threads compile packages"
  cd {{BUILD_DIR}} && make buildinfo
  cd {{BUILD_DIR}} && make diffconfig buildversion feedsversion
  cd {{BUILD_DIR}} && make target/compile -j$(nproc) IGNORE_ERRORS="m n"
  cd {{BUILD_DIR}} && make package/kernel/button-hotplug/compile -j$(nproc)
  cd {{BUILD_DIR}} && make package/compile -j$(nproc) IGNORE_ERRORS="m n"
  cd {{BUILD_DIR}} && make package/index

# Generate Firmware
[group: 'Firmware']
generate-firmware:
  cd {{BUILD_DIR}} && make package/install -j$(nproc) || make package/install -j1 V=s
  cd {{BUILD_DIR}} && make target/install -j$(nproc) || make target/install -j1 V=s
  cd {{BUILD_DIR}} && make json_overview_image_info
  cd {{BUILD_DIR}} && make checksum


# Make Firmware
[group: 'Firmware']
make-firmware:
  just custom-feeds
  just install-feeds
  just custom-config
  just download-packages
  just compile-packages
  just generate-firmware
  mkdir -p {{OUTPUT_DIR}} && cp -a {{BUILD_DIR}}/bin/targets/{{DEVICE_TARGET}}/{{DEVICE_SUBTARGET}}/* {{OUTPUT_DIR}}

# Run all steps to make firmware
make:
  just checkout
  just config
  just gen-env
  just make-toolchain
  just make-firmware

unsquashfs:
  rm -rf {{BUILD_DIR}} && mkdir {{BUILD_DIR}}
  unsquashfs -d {{BUILD_DIR}} {{OUTPUT_DIR}}/{{TOOLCHAIN_IMAGE}}


# Mount OverlayFS
mount-overlay:
  mkdir {{OVERLAY_DIR}}
  mkdir -p {{BUILD_DIR}}
  cd {{OVERLAY_DIR}} && mkdir lower upper work
  cd {{OVERLAY_DIR}} && squashfuse -o uid=$(id -u),gid=$(id -g) {{OUTPUT_DIR}}/{{TOOLCHAIN_IMAGE}} lower
  cd {{OVERLAY_DIR}} && fuse-overlayfs -o lowerdir=lower,upperdir=upper,workdir=work {{BUILD_DIR}}
  df -hT

# Unmount OverlayFS
umount-overlay:
  fusermount -u {{BUILD_DIR}}
  fusermount -u {{OVERLAY_DIR}}/lower
  rm -rf {{OVERLAY_DIR}}

# Remount OverlayFS
remount-overlay:
  just umount-overlay
  just mount-overlay

# Download OpenWrt configuration file for a specific version, target, and subtarget.
download-config version=VERSION target=DEVICE_TARGET subtarget=DEVICE_SUBTARGET:
  curl -L https://downloads.openwrt.org/releases/{{version}}/targets/{{target}}/{{subtarget}}/config.buildinfo -o {{CONFIG_FILE}}

clean:
  rm -rf .config
  rm -rf {{ENV_FILE}}
  rm -rf {{BUILD_DIR}}
  rm -rf {{OUTPUT_DIR}}
