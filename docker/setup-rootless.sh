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

# RHEL/AlmaLinux 10 ship iptables-nft but omit legacy xt_* modules from the base kernel
# package. Docker's bridge driver needs xt_addrtype (in kernel-modules-extra).
ensure_iptables_kernel_modules() {
    local kver module_path
    kver="$(uname -r)"
    module_path="/lib/modules/${kver}/kernel/net/netfilter/xt_addrtype.ko"

    echo "Step 6a: Ensuring iptables kernel modules for kernel ${kver}..."

    if [ ! -f "${module_path}" ] && [ ! -f "${module_path}.xz" ]; then
        echo "Installing kernel-modules-extra for the running kernel..."
        if ! dnf install -y "kernel-modules-extra-${kver}"; then
            dnf install -y kernel-modules-extra
        fi
    fi

    if [ ! -f "${module_path}" ] && [ ! -f "${module_path}.xz" ]; then
        echo "ERROR: xt_addrtype is not available for kernel ${kver}."
        echo "  Install kernel-modules-extra-${kver}, or reboot into a kernel that has it."
        exit 1
    fi

    if ! modprobe xt_addrtype 2>/dev/null; then
        echo "ERROR: failed to load xt_addrtype (required for Docker networking)."
        exit 1
    fi

    mkdir -p /etc/modules-load.d
    if [ ! -f /etc/modules-load.d/docker-iptables.conf ]; then
        echo xt_addrtype >/etc/modules-load.d/docker-iptables.conf
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

ensure_iptables_kernel_modules

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
if ! run_as_target_user '
    systemctl --user enable --now dbus 2>/dev/null \
        || systemctl --user enable --now dbus-broker 2>/dev/null \
        || true
    systemctl --user enable --now docker
'; then
    echo "ERROR: Failed to start docker.service for $TARGET_USER."
    run_as_target_user 'journalctl -n 30 --no-pager --user --unit docker.service' || true
    exit 1
fi

DOCKER_HOST="$(detect_docker_host)"

if ! run_as_target_user "export DOCKER_HOST='${DOCKER_HOST}'; systemctl --user is-active --quiet docker"; then
    echo "ERROR: docker.service is not active after install."
    run_as_target_user 'journalctl -n 30 --no-pager --user --unit docker.service' || true
    exit 1
fi

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
if ! run_as_target_user "export DOCKER_HOST='${DOCKER_HOST}'; docker --version && docker compose version && docker info 2>/dev/null | head -25"; then
    echo "ERROR: docker info failed. Check DOCKER_HOST=${DOCKER_HOST} and daemon logs above."
    exit 1
fi
echo ""
echo "To test rootless Docker (as $TARGET_USER):"
echo "  docker run hello-world"
