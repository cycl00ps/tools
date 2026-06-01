#!/bin/bash
# Docker Rootless Installation Script for AlmaLinux/RHEL 10

set -e

TARGET_USER="${1:-${SUDO_USER:-}}"
ENABLE_LINGER="${ENABLE_LINGER:-1}"

echo "========================================="
echo "Installing Docker (rootless) on AlmaLinux"
echo "========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

if [ -z "$TARGET_USER" ]; then
    echo "Usage: sudo $0 [username]"
    echo "  Or run with sudo so SUDO_USER is set."
    exit 1
fi

if ! id "$TARGET_USER" &>/dev/null; then
    echo "User $TARGET_USER does not exist."
    exit 1
fi

echo "Target user for rootless Docker: $TARGET_USER"
echo ""

echo "Step 1: Removing old Docker versions (if any)..."
dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

echo "Step 2: Installing required packages..."
dnf install -y dnf-plugins-core

echo "Step 3: Adding Docker repository..."
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true

echo "Step 4: Installing Docker Engine and rootless extras..."
dnf install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    docker-ce-rootless-extras \
    shadow-utils \
    slirp4netns \
    dbus-user-session

echo "Step 5: Disabling rootful Docker (rootless uses a per-user daemon)..."
systemctl disable --now docker.service docker.socket 2>/dev/null || true
rm -f /var/run/docker.sock

echo "Step 6: Configuring prerequisites for rootless mode..."

# User namespaces (required on some RHEL-family installs)
if [ "$(sysctl -n user.max_user_namespaces 2>/dev/null || echo 0)" -lt 1 ]; then
    echo "user.max_user_namespaces=28633" >/etc/sysctl.d/99-docker-rootless.conf
    sysctl --system >/dev/null
fi

# Subordinate UID/GID range (at least 65,536 IDs)
if ! grep -q "^${TARGET_USER}:" /etc/subuid 2>/dev/null; then
    usermod --add-subuids 100000-165535 "$TARGET_USER"
    echo "Assigned subuids 100000-165535 to $TARGET_USER"
fi
if ! grep -q "^${TARGET_USER}:" /etc/subgid 2>/dev/null; then
    usermod --add-subgids 100000-165535 "$TARGET_USER"
    echo "Assigned subgids 100000-165535 to $TARGET_USER"
fi

echo "Step 7: Installing rootless Docker for user $TARGET_USER..."
# Must run as the target user (not root)
runuser -l "$TARGET_USER" -c 'dockerd-rootless-setuptool.sh install'

if [ "$ENABLE_LINGER" = "1" ]; then
    echo "Step 8: Enabling linger (rootless Docker starts at boot without login)..."
    loginctl enable-linger "$TARGET_USER"
else
    echo "Step 8: Skipping linger (set ENABLE_LINGER=1 to enable)."
fi

TARGET_UID="$(id -u "$TARGET_USER")"
DOCKER_HOST="unix:///run/user/${TARGET_UID}/docker.sock"

echo "========================================="
echo "Rootless Docker installation complete!"
echo "========================================="
echo ""
echo "Log in as $TARGET_USER (or use: sudo -u $TARGET_USER -i)"
echo ""
echo "Manage the daemon:"
echo "  systemctl --user start|stop|restart docker"
echo ""
echo "If DOCKER_HOST is not set automatically, add to ~/.bashrc:"
echo "  export DOCKER_HOST=$DOCKER_HOST"
echo ""
echo "Verifying installation (as $TARGET_USER)..."
runuser -l "$TARGET_USER" -c "docker --version && docker compose version && docker info 2>/dev/null | head -20"
echo ""
echo "To test rootless Docker (as $TARGET_USER):"
echo "  docker run hello-world"
