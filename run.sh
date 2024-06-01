#!/bin/bash

# Colorize terminal
red='\e[0;31m'
no_color='\033[0m'


SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Default
FETCH_KUBECONFIG="false"
PLAYBOOK="false"
TAGS="all"
DECRYPT="false"
ENCRYPT="false"
UPDATE="false"

# Declare script helper
TEXT_HELPER="\nThis script aims to install a full homelab with gateway, bastion and k3s cluster.
Following flags are available:

  -d    Decrypt data using Sops.

  -e    Encrypt data using Sops.

  -k    Copy kubeconfig locally, default is '$FETCH_KUBECONFIG'.
        Kubeconfig is fetched to '$HOME/.kube/config.d/homelab' and
        a context, user and cluster are create in '$HOME/.kube/config' with name 'homelab'.

  -p    Run ansible playbook, default is '$PLAYBOOK'.
        Playbook should be passed as arg (ex: './run.sh -p ./kubernetes/ansible/services.yml').

  -t    Tags to run with playbook, default is '$TAGS'.
        This flag can be used with a CSV list (ex: -p 'init,services').

  -u    Update ansible dependencies.

  -h    Print script help.\n\n"

print_help() {
  printf "$TEXT_HELPER"
}

# Parse options
while getopts hdekp:t:u flag; do
  case "${flag}" in
    d)
      DECRYPT="true";;
    e)
      ENCRYPT="true";;
    k)
      FETCH_KUBECONFIG="true";;
    p)
      PLAYBOOK="${OPTARG}";;
    t)
      TAGS="${OPTARG}";;
    u)
      UPDATE="true";;
    h | *)
      print_help
      exit 0;;
  esac
done


if [ "$DECRYPT" = "true" ]; then
  printf "\n\n${red}[Homelab kube Manager].${no_color} Decrypt data using Sops\n\n"
  find ./argo-cd -name '*.enc.yaml' -exec bash -c 'sops -d {} > $(dirname {})/$(basename {} .enc.yaml).dec.yaml' \;
fi


if [ "$ENCRYPT" = "true" ]; then
  printf "\n\n${red}[Homelab kube Manager].${no_color} Encrypt data using Sops\n\n"
  find ./argo-cd -name '*.dec.yaml' -exec bash -c 'sops -e {} > $(dirname {})/$(basename {} .dec.yaml).enc.yaml' \;
fi


# Update ansible dependencies
if [ "$UPDATE" = "true" ]; then
  printf "\n\n${red}[Homelab kube Manager].${no_color} Update ansible collections\n\n"
  ansible-galaxy collection install -r $SCRIPT_PATH/ansible/collections/requirements.yml --upgrade
fi


# Run ansible
if [ ! "$PLAYBOOK" = "false" ]; then
  if [[ "$PLAYBOOK" =~ ^kubernetes/.* || "$PLAYBOOK" =~ ^\./kubernetes/.*  ]]; then
    PLAYBOOK="$(readlink -f $PLAYBOOK)"
    export ANSIBLE_CONFIG="$SCRIPT_PATH/$(echo $PLAYBOOK | sed 's|^\./||' | cut -d'/' -f1)/ansible/ansible.cfg"
    CONTEXT=$(kubectl config current-context)
    printf "\n\n${red}[Homelab kube Manager].${no_color} You are using kubeconfig context '$CONTEXT', do you want to continue (Y/n)?\n"
    read ANSWER
    if [ "$ANSWER" != "${ANSWER#[Nn]}" ]; then
      exit 1
    fi
  fi

  printf "\n\n${red}[Homelab kube Manager].${no_color} Run ansible playbook\n\n"
  if [ ! -z "$KUBECONFIG_PATH" ]; then
    ansible-playbook "$PLAYBOOK" --tag "$TAGS" -e K8S_AUTH_KUBECONFIG="$KUBECONFIG_PATH"
  elif [ ! -z "$KUBECONFIG" ]; then
    ansible-playbook "$PLAYBOOK" --tag "$TAGS" -e K8S_AUTH_KUBECONFIG="$KUBECONFIG"
  else
    ansible-playbook "$PLAYBOOK" --tag "$TAGS" -e K8S_AUTH_KUBECONFIG="$HOME/.kube/config"
  fi
fi


# Copy kube config to local machine
if [ "$FETCH_KUBECONFIG" = "true" ]; then
  printf "\n\n${red}[Homelab kube Manager].${no_color} Copy kube config locally\n\n"

  GATEWAY_IP=$(yq '[.gateway.hosts[][]][0]' infra/ansible/inventory/hosts.yml)
  MASTER_IP=$(yq '[.k3s.children.masters.hosts[][]][0]' infra/ansible/inventory/hosts.yml)
  USER=$(yq '.ansible_user' infra/ansible/inventory/group_vars/all.yml)

  mkdir -p $HOME/.kube/config.d
  scp $USER@$MASTER_IP:/etc/rancher/k3s/k3s.yaml $HOME/.kube/config.d/homelab
  CLUSTER_KUBECONFIG="$(sed "s/127.0.0.1/$GATEWAY_IP/g" $HOME/.kube/config.d/homelab)"
  echo "$CLUSTER_KUBECONFIG" > $HOME/.kube/config.d/homelab

  export CLUSTER_CERTIFICATE_AUTHORITY_DATA="$(yq '.clusters[0].cluster.certificate-authority-data' $HOME/.kube/config.d/homelab)"
  export CLUSTER_SERVER="$(yq '.clusters[0].cluster.server' $HOME/.kube/config.d/homelab)"
  export USER_CLIENT_CERTIFICATE_DATA="$(yq '.users[0].user.client-certificate-data' $HOME/.kube/config.d/homelab)"
  export USER_CLIENT_KEY_DATA="$(yq '.users[0].user.client-key-data' $HOME/.kube/config.d/homelab)"

  yq -i '(.clusters[] | select(.name == "homelab") | .cluster.certificate-authority-data) = env(CLUSTER_CERTIFICATE_AUTHORITY_DATA)' ~/.kube/config
  yq -i '(.clusters[] | select(.name == "homelab") | .cluster.server) = env(CLUSTER_SERVER)' ~/.kube/config
  yq -i '(.users[] | select(.name == "homelab") | .user.client-certificate-data) = env(USER_CLIENT_CERTIFICATE_DATA)' ~/.kube/config
  yq -i '(.users[] | select(.name == "homelab") | .user.client-key-data) = env(USER_CLIENT_KEY_DATA)' ~/.kube/config
fi
