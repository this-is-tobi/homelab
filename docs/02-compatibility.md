# Compatibility

## Hardware

Any equipment can be used, but it has been tested with the following items :
- 9 x Raspberry (Pi 4 model B - 8GB)
- 1 x Raspberry (Pi 4 model B - 4GB)
- 3 x Switch TP-Link (TL-SG 105E)
- 4 x 2TB HDD (HDTP320EK3AA)

## Operating System

All raspberries are running with `Raspberry Pi OS (64-bit)` but any Debian based system should work.

For Raspberry, see :
- <https://www.raspberrypi.com/software>
- <https://www.raspberrypi.com/software/operating-systems>

> *To perform multiple OS installation in parallel on multiple devices take a look at [setup-pi.sh](../scripts/setup-pi.sh) script.*


## Access

Each target server __should have a static IP address__ to maintain consistency in the inventory file [hosts.yml](../ansible/inventory-example/hosts.yml), update this file with the appropriate values.

__SSH access to all machines is needed to install infrastructure__, username/password or ssh key could be used.

__Kubernetes admin access is needed to install services__, it use kubeconfig and the [run.sh](../run.sh) wrapper script will ask to confirm the context.
