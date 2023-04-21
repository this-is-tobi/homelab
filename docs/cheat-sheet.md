# Cheat Sheet

## Network

```sh
# Find ips on local subnet
sudo nmap -sN 192.168.0.1/24
```

## Disk

```sh
# List disks
lsblk -f 

# umount /dev/sda1
sudo wipefs -a /dev/sda

# use ext4 filesystem for /dev/sda
sudo mkfs.ext4 /dev/sda

# mount volume
sudo mkdir /storage01
sudo mount /dev/sda /storage01

VAR_UUID=$(lsblk -n -o UUID /dev/sda)
sudo su -c "echo 'UUID=$VAR_UUID  /storage01       ext4    defaults        0       2' >> /etc/fstab"
```

## System

```sh
# Restart host
sudo reboot
```

## Secrets

```sh
# Generate strong secret with openssl
openssl rand -base64 36
```

## Kubernetes

```sh
# Get pod by node
kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName=<node>

# Get node labels
kubectl get nodes --show-labels

# Create and apply secret from file 
kubectl create secret -n <namespace> generic <secret_name> \
  --from-file=<file_name>.yaml \
  --dry-run=client \
  -o yaml \
  | kubectl apply -f -

# Read secret
kubectl -n <namespace> get secret <secret_name> -o jsonpath="{.data.<data_field>}" | base64 --decode

# Forward port 
kubectl port-forward -n <namespace> svc/<service_name> <host_port>:<service_port>
kubectl port-forward -n <namespace> pod/<pod_name> <host_port>:<pod_port>
```

## Minio

```sh
# Generate S3 format secret key
SecureRandom.urlsafe_base64(30)

# Install docker minio client (CLI)
docker pull minio/mc

# Register minio client alias
docker run minio/mc alias set homelab https://minio.domain.com $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
```

## Local registry

```sh
# Login to registry
docker login <registry_domain>

# List images in a registry
curl -X GET https://<registry_domain>/v2/_catalog

# Push image to registry
docker tag <image_name>:<image_tag> <registry_domain>/<image_name>:<image_tag>
docker push <registry_domain>/<image_name>:<image_tag>

# You can now pull the image
docker pull <registry_domain>/<image_name>:<image_tag>

# ---
# Build multiarch images
docker login <registry_domain>

## Create buildx namespace
docker buildx create --use --name <buildx_namespace>

## Inspect buildx namespace
docker buildx inspect --bootstrap <buildx_namespace>

## Upload image to private registry specifying options (e.g platform linux/arm64)
docker buildx build \
  --platform linux/arm64,linux/amd64 \
  --tag <registry_domain>/<image_name>:<image_tag> \
  --push \
  <dockerfile_folder>
```
