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

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "Target user for rootless Docker: $TARGET_USER"
echo ""

# Run a command as the target user in a pam_systemd-capable session.
# runuser/su do not set XDG_RUNTIME_DIR; machinectl shell does (Docker docs).
run_as_target_user() {
    local cmd="$1"
    if command -v machinectl &>/dev/null; then
        machinectl shell "${TARGET_USER}@" /bin/bash -lc "$cmd"
    elif [ -d "/run/user/${TARGET_UID}" ]; then
        runuser -l "$TARGET_USER" -c "
            export XDG_RUNTIME_DIR=/run/user/${TARGET_UID}
            export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${TARGET_UID}/bus
            $cmd
        "
    else
        echo "ERROR: Cannot run as $TARGET_USER with a systemd user session."
        echo "  Install systemd-container (for machinectl) or enable linger and ensure /run/user/${TARGET_UID} exists."
        return 1
    fi
}

ensure_user_systemd_session() {
    if [ "$ENABLE_LINGER" = "1" ]; then
        echo "Enabling linger for $TARGET_USER (user systemd runs without interactive login)..."
        loginctl enable-linger "$TARGET_USER"
    fi
    systemctl start "user@${TARGET_UID}.service" 2>/dev/null || true
    if [ ! -d "/run/user/${TARGET_UID}" ]; then
        echo "WARNING: /run/user/${TARGET_UID} not present yet."
        echo "  Linger may need a moment, or log in once as $TARGET_USER via SSH before re-running."
    fi
}

detect_docker_host() {
    if [ -S "/run/user/${TARGET_UID}/docker.sock" ]; then
        echo "unix:///run/user/${TARGET_UID}/docker.sock"
    elif [ -S "${TARGET_HOME}/.docker/run/docker.sock" ]; then
        echo "unix://${TARGET_HOME}/.docker/run/docker.sock"
    else
        echo "unix:///run/user/${TARGET_UID}/docker.sock"
    fi
}

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
    dbus-daemon \
    systemd-container

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

echo "Step 6b: Preparing systemd user session for $TARGET_USER..."
ensure_user_systemd_session

echo "Step 7: Installing rootless Docker for user $TARGET_USER..."
SETUP_OUTPUT="$(run_as_target_user 'dockerd-rootless-setuptool.sh install' 2>&1)" || {
    echo "$SETUP_OUTPUT"
    echo "ERROR: dockerd-rootless-setuptool.sh install failed."
    exit 1
}
echo "$SETUP_OUTPUT"
if echo "$SETUP_OUTPUT" | grep -q 'systemd not detected'; then
    echo "WARNING: setuptool reported systemd not detected; user docker.service may be missing."
    echo "  Re-run after SSH login as $TARGET_USER, or use: machinectl shell ${TARGET_USER}@ ..."
fi

echo "Step 8: Enabling and starting rootless Docker (user systemd units)..."
run_as_target_user '
    systemctl --user enable --now dbus 2>/dev/null \
        || systemctl --user enable --now dbus-broker 2>/dev/null \
        || true
    systemctl --user enable --now docker
'

DOCKER_HOST="$(detect_docker_host)"

echo "========================================="
echo "Rootless Docker installation complete!"
echo "========================================="
echo ""
if [ "$ENABLE_LINGER" = "1" ]; then
    echo "Linger is enabled for $TARGET_USER (daemon can start at boot)."
else
    echo "Linger is disabled; the user daemon starts after $TARGET_USER logs in."
fi
echo ""
echo "Log in as $TARGET_USER via SSH (not sudo su / sudo -i)."
echo ""
echo "Manage the daemon:"
echo "  systemctl --user start|stop|restart docker"
echo ""
echo "If DOCKER_HOST is not set automatically, add to ~/.bashrc:"
echo "  export DOCKER_HOST=$DOCKER_HOST"
echo ""
echo "Verifying installation (as $TARGET_USER)..."
run_as_target_user "docker --version && docker compose version && docker info 2>/dev/null | head -25"
echo ""
echo "To test rootless Docker (as $TARGET_USER):"
echo "  docker run hello-world"
