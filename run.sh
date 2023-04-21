#!/bin/bash

# Colorize terminal
red='\e[0;31m'
no_color='\033[0m'

# Console step increment
i=1


SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Default
COPY_KUBECONFIG="false"
RUN_PLAYBOOK="false"
TAGS="all"

# Declare script helper
TEXT_HELPER="\nThis script aims to install a full homelab with gateway, bastion and k3s cluster.
Following flags are available:

  -k    Copy kubeconfig locally, default is '$COPY_KUBECONFIG'.
        Directory dest should be passed as arg.

  -p    Run ansible playbook, default is '$RUN_PLAYBOOK'.

  -t    Tags to run with playbook, default is '$TAGS'.
        This flag can be used with a CSV list (ex: -p 'init,services').

  -h    Print script help.\n\n"

print_help() {
  printf "$TEXT_HELPER"
}

# Parse options
while getopts hk:pt: flag; do
  case "${flag}" in
    k)
      COPY_KUBECONFIG="true"
      KUBECONFIG_OUTPUT="${OPTARG}";;
    p)
      RUN_PLAYBOOK="true";;
    t)
      TAGS="${OPTARG}";;
    h | *)
      print_help
      exit 0;;
  esac
done


# Run ansible
if [ "$RUN_PLAYBOOK" = "true" ]; then
  printf "\n\n${red}${i}.${no_color} Update ansible collections\n\n"
  i=$(($i + 1))

  ansible-galaxy collection install -r $SCRIPT_PATH/ansible/collections/requirements.yml --upgrade


  printf "\n\n${red}${i}.${no_color} Run ansible playbook\n\n"
  i=$(($i + 1))

  ansible-playbook $SCRIPT_PATH/ansible/homelab.yml --inventory $SCRIPT_PATH/ansible/inventory/hosts.yml --tag "$TAGS"
fi

# Copy kube config to local machine
if [ "$COPY_KUBECONFIG" = "true" ]; then
  printf "\n\n${red}${i}.${no_color} Copy kube config locally\n\n"
  i=$(($i + 1))

  GATEWAY_IP=$(cat ansible/inventory/hosts.yml | yq '[.all.children.gateway.hosts[][]][0]')
  MASTER_IP=$(cat ansible/inventory/hosts.yml | yq '[.all.children.cluster.children.masters.hosts[][]][0]')
  USER=$(cat ansible/inventory/group_vars/all.yml | yq '.ansible_user')

  scp $USER@$MASTER_IP:/etc/rancher/k3s/k3s.yaml $KUBECONFIG_OUTPUT/kubeconfig
  KUBECONFIG="$(sed "s/127.0.0.1/$GATEWAY_IP/g" $KUBECONFIG_OUTPUT/kubeconfig)"
  echo "$KUBECONFIG" > $KUBECONFIG_OUTPUT/kubeconfig
fi
