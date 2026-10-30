#!/bin/bash
# Run as root on a fresh DigitalOcean Ubuntu 26.04 droplet.
set -Eeuo pipefail
umask 077

if [[ $(id -u) != 0 ]]; then
  echo 'Run this script as root.' >&2
  exit 1
fi

log_file=/var/log/t3-droplet-setup.log
exec > >(tee -a "$log_file") 2>&1
trap 'echo "Setup failed at line $LINENO. See /var/log/t3-droplet-setup.log." >&2' ERR

# This provisions a host, not a container or a developer workstation.
# shellcheck source=/dev/null
source /etc/os-release
if [[ $ID != ubuntu || $VERSION_ID != 26.04 || ! -d /run/systemd/system ]]; then
  echo 'This script requires an Ubuntu 26.04 host running systemd.' >&2
  exit 1
fi

# DigitalOcean adds the SSH keys selected during creation to this file.
# Fail before installing anything if there is no key to authorize for t3.
if [[ ! -s /root/.ssh/authorized_keys ]]; then
  echo 'Select an SSH key when creating this droplet.' >&2
  exit 1
fi

# Check an existing account before changing packages or SSH configuration.
if id t3 >/dev/null 2>&1; then
  if [[ $(id -u t3) == 0 || $(getent passwd t3 | cut -d: -f6) != /home/t3 ||
        $(getent passwd t3 | cut -d: -f7) != /bin/bash ]]; then
    echo 'Existing t3 account must be non-root with home /home/t3 and shell /bin/bash.' >&2
    exit 1
  fi
  if id -nG t3 | tr ' ' '\n' | grep -Eq '^(root|sudo|admin|docker|lxd|incus-admin)$'; then
    echo 'Existing t3 account has privileged group membership; review it first.' >&2
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git gh ripgrep unzip xz-utils dbus-user-session

if ! id t3 >/dev/null 2>&1; then
  useradd --create-home --user-group --shell /bin/bash --comment 'T3 agent user' t3
  passwd --lock t3
fi
agent_group=$(id -gn t3)

install -d -m 0700 -o t3 -g "$agent_group" /home/t3/.ssh
# Preserve keys added directly to t3 when provisioning is rerun.
key_file=$(mktemp)
trap 'rm -f "$key_file"' EXIT
ssh_key_sources=(/root/.ssh/authorized_keys)
if [[ -f /home/t3/.ssh/authorized_keys ]]; then
  ssh_key_sources=(/home/t3/.ssh/authorized_keys /root/.ssh/authorized_keys)
fi
awk '!seen[$0]++' "${ssh_key_sources[@]}" > "$key_file"
install -m 0600 -o t3 -g "$agent_group" "$key_file" /home/t3/.ssh/authorized_keys
rm -f "$key_file"
install -d -m 0755 -o t3 -g "$agent_group" /home/t3/projects

# Restrict the agent account without changing other users' login policies.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-agent-key-only.conf <<'SSH'
Match User t3
    PasswordAuthentication no
    KbdInteractiveAuthentication no
Match all
SSH
/usr/sbin/sshd -t
systemctl reload ssh.service

# A user systemd manager must exist even when t3 has never logged in.
loginctl enable-linger t3
agent_uid=$(id -u t3)
systemctl start "user@${agent_uid}.service"

install -d -m 0755 /usr/local/libexec
cat > /usr/local/libexec/install-agent-tools <<'TOOLS'
#!/bin/bash
set -Eeuo pipefail
trap 'echo "Agent tool installation failed at line $LINENO." >&2' ERR
test "$(id -un)" = t3
cd /home/t3
umask 077
export PATH="/home/t3/.local/bin:/usr/local/bin:/usr/bin:/bin"
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# Versions observed on the original droplet. Update intentionally.
export T3CODE_VERSION=0.1.5
export CODEX_RELEASE=0.166.0
export CODEX_NON_INTERACTIVE=1

mkdir -p /home/t3/.local/bin
# Ubuntu can mount /tmp as a small tmpfs. Codex's archive exceeds it on
# small droplets; keep both installers' temporary downloads on disk instead.
mkdir -p /home/t3/.cache/t3-setup
export TMPDIR=/home/t3/.cache/t3-setup
installer_dir=$(mktemp -d)
trap 'rm -rf "$installer_dir"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  https://t3.codes/install.sh -o "$installer_dir/t3.sh"
sh "$installer_dir/t3.sh"
curl --fail --silent --show-error --location --retry 3 \
  https://chatgpt.com/codex/install.sh -o "$installer_dir/codex.sh"
sh "$installer_dir/codex.sh" </dev/null

mkdir -p /home/t3/.config/systemd/user/t3code.service.d
cat > /home/t3/.config/systemd/user/t3code.service.d/path.conf <<'UNIT'
[Service]
Environment="PATH=/home/t3/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
UNIT

# Keep the HTTP server private; T3 Connect supplies remote access.
# Preserve service settings if this is a repair of an existing installation.
if [[ ! -e /home/t3/.t3/service.env ]]; then
  printf 'T3CODE_HOST=127.0.0.1\n' > /home/t3/.t3/service.env
fi
systemctl --user daemon-reload
t3 service install
systemctl --user is-enabled t3code.service
systemctl --user is-active t3code.service
t3 --version
codex --version
gh --version
TOOLS
chmod 0755 /usr/local/libexec/install-agent-tools
runuser --login t3 --command /usr/local/libexec/install-agent-tools

cat <<'NEXT'
Setup complete. Open a new SSH session as t3 (ssh t3@YOUR_DROPLET_IP).
Keep root access for administration; t3 has no sudo privileges.
Run the following as t3, without sudo:
  codex login --device-auth
  gh auth login --hostname github.com --git-protocol https --web
  gh auth setup-git
  t3 connect link --headless
  t3 service restart
  t3 connect status

Enable device-code login in ChatGPT Settings > Security before Codex login.
Use the same T3 Connect account on the droplet and your other devices.
If the tunnel is still starting, wait a minute and run t3 connect status again.
NEXT

