#!/bin/bash

# Colorize terminal
red='\e[0;31m'
no_color='\033[0m'


SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Default
export ANSIBLE_CONFIG="$SCRIPT_PATH/ansible/ansible.cfg"
FETCH_KUBECONFIG="false"
PLAYBOOK="false"
TAGS="all"
DECRYPT="false"
ENCRYPT="false"

# Declare script helper
TEXT_HELPER="\nThis script aims to install a full homelab with gateway, bastion and k3s cluster.
Following flags are available:

  -d    Decrypt data using Sops.

  -e    Encrypt data using Sops.

  -k    Copy kubeconfig locally, default is '$FETCH_KUBECONFIG'.
        Directory output should be passed as arg.

  -p    Run ansible playbook, default is '$PLAYBOOK'.
        Playbook should be passed as arg.

  -t    Tags to run with playbook, default is '$TAGS'.
        This flag can be used with a CSV list (ex: -p 'init,services').

  -h    Print script help.\n\n"

print_help() {
  printf "$TEXT_HELPER"
}

# Parse options
while getopts hdek:p:t: flag; do
  case "${flag}" in
    d)
      DECRYPT="true";;
    e)
      ENCRYPT="true";;
    k)
      FETCH_KUBECONFIG="true";;
    p)
      PLAYBOOK="$(readlink -f ${OPTARG})";;
    t)
      TAGS="${OPTARG}";;
    h | *)
      print_help
      exit 0;;
  esac
done


if [ "$DECRYPT" = "true" ]; then
  printf "\n\n${red}[Homelab kube Manager].${no_color} Decrypt data using Sops\n\n"
  find ./argocd -name '*.enc.yaml' -exec bash -c 'sops -d {} > $(dirname {})/$(basename {} .enc.yaml).dec.yaml' \;
fi


if [ "$ENCRYPT" = "true" ]; then
  printf "\n\n${red}[Homelab kube Manager].${no_color} Encrypt data using Sops\n\n"
  find ./argocd -name '*.dec.yaml' -exec bash -c 'sops -e {} > $(dirname {})/$(basename {} .dec.yaml).enc.yaml' \;
fi


# Run ansible
if [ ! "$PLAYBOOK" = "false" ]; then
  CONTEXT=$(kubectl config current-context)
  printf "\n\n${red}[Homelab kube Manager].${no_color} You are using kubeconfig context '$CONTEXT', do you want to continue (y/n)?\n"
  read ANSWER
  if [ "$ANSWER" != "${ANSWER#[Nn]}" ]; then
      exit 1
  fi

  printf "\n\n${red}[Homelab kube Manager].${no_color} Update ansible collections\n\n"
  ansible-galaxy collection install -r $SCRIPT_PATH/ansible/collections/requirements.yml --upgrade

  printf "\n\n${red}[Homelab kube Manager].${no_color} Run ansible playbook\n\n"
  if [ ! -z "$KUBECONFIG_PATH" ]; then
    echo "$KUBECONFIG_PATH"
    ansible-playbook "$PLAYBOOK" --tag "$TAGS" -e K8S_AUTH_KUBECONFIG="$KUBECONFIG_PATH"
  elif [ ! -z "$KUBECONFIG" ]; then
    echo "$KUBECONFIG"
    ansible-playbook "$PLAYBOOK" --tag "$TAGS" -e K8S_AUTH_KUBECONFIG="$KUBECONFIG"
  else
    echo "$HOME/.kube/config"
    ansible-playbook "$PLAYBOOK" --tag "$TAGS" -e K8S_AUTH_KUBECONFIG="$HOME/.kube/config"
  fi
fi


# Copy kube config to local machine
if [ ! "$FETCH_KUBECONFIG" = "false" ]; then
  printf "\n\n${red}[Homelab kube Manager].${no_color} Copy kube config locally\n\n"

  GATEWAY_IP=$(cat ansible/inventory/hosts.yml | yq '[.all.children.gateway.hosts[][]][0]')
  MASTER_IP=$(cat ansible/inventory/hosts.yml | yq '[.all.children.cluster.children.masters.hosts[][]][0]')
  USER=$(cat ansible/inventory/group_vars/all.yml | yq '.ansible_user')

  scp $USER@$MASTER_IP:/etc/rancher/k3s/k3s.yaml $KUBECONFIG/kubeconfig
  CLUSTER_KUBECONFIG="$(sed "s/127.0.0.1/$GATEWAY_IP/g" $KUBECONFIG/kubeconfig)"
  echo "$CLUSTER_KUBECONFIG" > $KUBECONFIG/kubeconfig
fi
