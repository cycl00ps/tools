#!/bin/bash
# Docker Installation Script for AlmaLinux/RHEL

set -e

echo "========================================="
echo "Installing Docker on AlmaLinux"
echo "========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

echo "Step 1: Removing old Docker versions (if any)..."
dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

echo "Step 2: Installing required packages..."
dnf install -y dnf-plugins-core

echo "Step 3: Adding Docker repository..."
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

echo "Step 4: Installing Docker Engine..."
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Step 5: Starting and enabling Docker service..."
systemctl start docker
systemctl enable docker

echo "Step 6: Adding current user to docker group (if not root)..."
if [ -n "$SUDO_USER" ]; then
    usermod -aG docker "$SUDO_USER"
    echo "User $SUDO_USER added to docker group. You may need to log out and back in for this to take effect."
fi

echo "========================================="
echo "Docker installation complete!"
echo "========================================="
echo ""
echo "Verifying installation..."
docker --version
docker compose version

echo ""
echo "To use Docker without sudo, log out and log back in, or run:"
echo "  newgrp docker"
echo ""
echo "To test Docker, run:"
echo "  docker run hello-world"

