#!/usr/bin/env bash

# Script to create a logs directory on Unraid when the Array starts so that it exists after a reboot
create_dir() {
    mkdir -p /var/log/rsync
}

# Main function to run all other functions
main() {
    create_dir
}

main