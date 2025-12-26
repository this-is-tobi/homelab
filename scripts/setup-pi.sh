#!/bin/bash

set -e
set -o pipefail

# Colorize terminal
red='\e[0;31m'
green='\e[0;32m'
yellow='\e[0;33m'
no_color='\033[0m'

SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Variables
DOWNLOAD_DIRECTORY="./tmp"
IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2023-12-11/2023-12-11-raspios-bookworm-arm64-lite.img.xz"
IMAGE_BASE_NAME="${IMAGE_URL##*/}"
IMAGE_BASE_PATH="${DOWNLOAD_DIRECTORY}/${IMAGE_BASE_NAME}"
IMAGE_NAME="${IMAGE_BASE_NAME%.*}"
IMAGE_PATH="${DOWNLOAD_DIRECTORY}/${IMAGE_NAME}"

# Functions
download_image () {
  printf "\n\n${red}[Pi image manager].${no_color} Download RaspiOS image.\n\n"

  mkdir -p $DOWNLOAD_DIRECTORY
  curl "$IMAGE_URL" -O "$IMAGE_BASE_PATH"
  curl "$IMAGE_URL.sha256" -O "$IMAGE_BASE_PATH.sha256"
  sha256sum -c "$IMAGE_BASE_PATH.sha256"
  xz -d -v "$IMAGE_BASE_PATH"
}

copy_image () {
  printf "  > writing image $1 to $2 - ${yellow}Pending..${no_color}\n"

  sudo diskutil unmountDisk $2
  sudo dd if=$1 of=$2 bs=8m status=progress

  printf "  > writing image $1 to $2 - ${green}Ok${no_color}\n"
}


# Run script
if [ ! -f "$IMAGE_PATH" ]; then
  download_image
fi


printf "\n\n${red}[Pi image manager].${no_color} Copy image to external disk.\n\n"

for disk in $(diskutil list | grep '/dev' | grep 'external' | awk '{print $1}'); do
  copy_image "$IMAGE_PATH" "$disk" &
  JOBS+=($!)
done


printf "\n\n${red}[Pi image manager].${no_color} Wait for copy to be complete.\n\n"

for job in ${JOBS[@]}; do
  printf "  > waiting for job: $job - ${yellow}Pending..${no_color}\n"
  wait "$job"
  printf "  > waiting for job: $job - ${green}Ok${no_color}\n\n"
done


printf "\n\n${red}[Pi image manager].${no_color} Copy image to external disk.\n\n"

export USERNAME="$(yq '.ansible_user' $SCRIPT_PATH/../ansible/inventory/group_vars/all.yml)"
export PASSWORD="$(yq '.ansible_password' $SCRIPT_PATH/../ansible/inventory/group_vars/all.yml)"

if [ -z "$USERNAME" ]; then
  export USERNAME="debian"
  yq -i '.ansible_user = env(USERNAME)' "$SCRIPT_PATH/../ansible/inventory/group_vars/all.yml"
fi

if [ -z "$PASSWORD" ]; then
  export PASSWORD="$(openssl rand -base64 15)"
  yq -i '.ansible_password = env(PASSWORD)' "$SCRIPT_PATH/../ansible/inventory/group_vars/all.yml"
fi

find /Volumes -type d -name 'bootfs*' -maxdepth 1 -exec sh -c '
  for volume do
    touch "$volume/ssh"
    touch "$volume/userconf.txt"
    ENCRYPTED_PASSWORD="$(echo $PASSWORD | openssl passwd -6 -stdin)"
    echo "$USERNAME:$ENCRYPTED_PASSWORD" > "$volume/userconf.txt"
    echo "dtoverlay=disable-wifi\ndtoverlay=disable-bt" >> "$volume/config.txt"
  done
' exec-sh {} +
