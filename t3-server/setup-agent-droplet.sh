#!/bin/bash
# Run as root on a fresh DigitalOcean Ubuntu 26.04 droplet.
set -euo pipefail
umask 077
trap 'echo "Setup failed at line $LINENO. See /var/log/cloud-init-output.log." >&2' ERR

if [[ $(id -u) != 0 ]]; then
  echo 'Run this script as root.' >&2
  exit 1
fi

# DigitalOcean adds the SSH keys selected during creation to this file.
# Fail before installing anything if there is no key to authorize for t3.
if [[ ! -s /root/.ssh/authorized_keys ]]; then
  echo 'Select an SSH key when creating this droplet.' >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git gh ripgrep unzip xz-utils dbus-user-session

if ! id t3 >/dev/null 2>&1; then
  useradd --create-home --user-group --shell /bin/bash --comment 'T3 agent user' t3
  passwd --lock t3
fi
# Do not silently reuse an account with administrative group membership.
if id -nG t3 | tr ' ' '\n' | grep -Eq '^(sudo|admin|docker|lxd|incus-admin)$'; then
  echo 'Existing t3 account has privileged group membership; review it first.' >&2
  exit 1
fi

install -d -m 0700 -o t3 -g t3 /home/t3/.ssh
install -m 0600 -o t3 -g t3 /root/.ssh/authorized_keys /home/t3/.ssh/authorized_keys
install -d -m 0755 -o t3 -g t3 /home/t3/projects

# Configure key-only SSH access. Keep root/admin access for maintenance.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-agent-key-only.conf <<'SSH'
PasswordAuthentication no
KbdInteractiveAuthentication no
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
set -euo pipefail
test "$(id -un)" = t3
cd /home/t3
umask 077
export PATH="/home/t3/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# Versions observed on the original droplet. Update intentionally.
export T3CODE_VERSION=0.1.5
export CODEX_RELEASE=0.166.0
export CODEX_NON_INTERACTIVE=1

mkdir -p /home/t3/.local/bin
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
Setup complete. Log in as t3 and authenticate:
  codex login --device-auth
  gh auth login --hostname github.com --git-protocol https --web
  gh auth setup-git
  t3 connect link --headless
  t3 service restart
  t3 connect status
NEXT

