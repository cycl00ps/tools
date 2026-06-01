# Docker setup scripts (AlmaLinux 10)

Shell scripts to install Docker Engine from the official Docker CE repository on AlmaLinux 10 (and compatible RHEL-family systems). Two modes are supported: a traditional rootful daemon and a rootless per-user daemon.

## Scripts

| Script | Mode | Daemon runs as |
|--------|------|----------------|
| [`setup.sh`](setup.sh) | Rootful (default Docker) | `root` via `docker.service` |
| [`setup-rootless.sh`](setup-rootless.sh) | Rootless | The target Linux user via `systemd --user` |

Both scripts require **root** (e.g. `sudo`). They use `dnf`, add `https://download.docker.com/linux/centos/docker-ce.repo`, and install Docker CE with Buildx and Compose plugins.

## Prerequisites

- AlmaLinux 10 (or similar RHEL 10–family release)
- Root or `sudo`
- Outbound network access to Docker’s package repository
- For rootless: a normal login user account (not only `root`)

## Rootful install (`setup.sh`)

Installs Docker Engine, enables the system-wide `docker` service, and adds `$SUDO_USER` to the `docker` group when you run the script with `sudo`.

**What it does:**

1. Removes old distribution Docker packages if present
2. Adds the Docker CE `dnf` repository
3. Installs `docker-ce`, CLI, `containerd`, Buildx, and Compose
4. Starts and enables `docker.service`
5. Adds the invoking sudo user to the `docker` group

**Usage:**

```bash
sudo bash setup.sh
```

**After install:**

- Log out and back in, or run `newgrp docker`, so group membership applies
- Test: `docker run hello-world`
- Manage the daemon: `sudo systemctl start|stop|restart docker`

## Rootless install (`setup-rootless.sh`)

Installs the same Docker CE packages plus rootless support, turns off the rootful `docker` service, configures host prerequisites, and runs `dockerd-rootless-setuptool.sh install` for one user. The daemon and containers run without root privileges in a user namespace.

**What it does:**

1. Same cleanup and repository setup as `setup.sh`
2. Installs rootless extras and dependencies (`docker-ce-rootless-extras`, `shadow-utils`, `slirp4netns`, `dbus-daemon`, `systemd-container`)
3. Disables `docker.service` and `docker.socket` (rootless does not use `/var/run/docker.sock`)
4. Ensures `user.max_user_namespaces` and subuid/subgid mappings for the target user
5. Enables **linger** by default (before setuptool) and starts the target user’s `user@.service` so `/run/user/<uid>` exists
6. Runs `dockerd-rootless-setuptool.sh install` via `machinectl shell` (a real login session; `runuser`/`sudo` cannot see systemd)
7. Enables and starts `docker.service` under `systemctl --user` for that user

**Usage:**

```bash
# Install for the user who invoked sudo
sudo bash setup-rootless.sh

# Install for a specific user
sudo bash setup-rootless.sh alice

# Skip boot-time linger (daemon only after user logs in)
ENABLE_LINGER=0 sudo bash setup-rootless.sh alice
```

**After install (as the target user):**

- Log in via **SSH** or the graphical console (not `sudo su` / `sudo -i`)
- Control the daemon: `systemctl --user start|stop|restart docker`
- Socket (normal path): `unix:///run/user/<uid>/docker.sock` (the script prints the exact `DOCKER_HOST` value)
- If the CLI does not pick up rootless automatically, add to `~/.bashrc`:
  ```bash
  export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
  ```
- Test: `docker run hello-world`
- Confirm rootless mode: `docker info` should show `rootless` under security options and a populated **Server** section

Official reference: [Docker rootless mode](https://docs.docker.com/engine/security/rootless/).

If `systemctl --user` reports **Failed to connect to bus**, log in again via SSH or the graphical console (not `sudo su` / `sudo -i`), then as the target user run `systemctl --user enable --now dbus` (or `dbus-broker` if that is the active user unit). See [Docker rootless troubleshooting](https://docs.docker.com/engine/security/rootless/troubleshoot/).

If setuptool fell back to non-systemd mode (socket under `~/.docker/run/`), see **Recovery** below.

### Recovery (broken or partial install)

Use this if a previous run printed `systemd not detected`, `docker.service not found`, or `docker ps` cannot connect.

1. Uninstall the old rootless setup. As the target user over SSH:

   ```bash
   dockerd-rootless-setuptool.sh uninstall
   ```

   If that fails (no user bus), as root:

   ```bash
   machinectl shell lab03@ /bin/bash -lc 'dockerd-rootless-setuptool.sh uninstall'
   ```

   (Replace `lab03` with your username.)

2. Re-run the updated script:

   ```bash
   sudo ./setup-rootless.sh lab03
   ```

3. Confirm (as the target user):

   ```bash
   systemctl --user status docker
   docker info
   docker run hello-world
   ```

   Expect `docker.service` active, socket at `unix:///run/user/$(id -u)/docker.sock`, and `docker info` showing `rootless` with a running server.

## Choosing rootful vs rootless

| | Rootful (`setup.sh`) | Rootless (`setup-rootless.sh`) |
|--|----------------------|--------------------------------|
| **Setup** | One system daemon | Per-user daemon |
| **Privileges** | Daemon runs as root; users in `docker` group can control it (effectively root-equivalent) | Daemon and containers run as the unprivileged user |
| **Socket** | `/var/run/docker.sock` | `/run/user/<uid>/docker.sock` |
| **Boot** | `docker.service` enabled | User unit + `loginctl linger` (optional) |
| **Typical use** | Shared server, simplest compatibility | Hardening, dev boxes, no root-equivalent group |

Do not run both scripts expecting two active daemons on one host: rootless disables the rootful service. Pick one approach per machine (or reinstall consciously if you switch).

## Notes

- Re-running `setup.sh` on a host that already has the Docker repo may fail at “add repo” if the repo file exists; remove the repo file or adjust the command if you need a clean re-add.
- Rootless assigns subuids `100000-165535` only if the user has no existing `/etc/subuid` / `/etc/subgid` entry.
- These scripts target AlmaLinux 10; other RHEL 10–compatible systems may work but are untested here.
