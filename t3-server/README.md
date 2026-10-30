# T3 Code on a DigitalOcean droplet

An Ubuntu server for coding agents that keeps working after you close your laptop.
Run [T3 Code](https://t3.codes), [Codex CLI](https://learn.chatgpt.com/docs/cli), and
[GitHub CLI](https://cli.github.com) on the droplet, then control your projects from
T3 Code on your Mac, browser, or phone through T3 Connect.

Your repositories, agent processes, and credentials live on the droplet. T3 Connect
provides remote access through an outbound tunnel, so you do not need to expose
T3's HTTP port to the internet.

## What the script sets up

| Component | Setup |
| --- | --- |
| Agent account | `t3`, without sudo privileges, with SSH keys copied from root |
| Workspace | `/home/t3/projects` |
| T3 Code | Version `0.1.5`, installed for `t3` |
| Codex CLI | Version `0.166.0`, installed for `t3` |
| GitHub CLI | `gh` from Ubuntu's package repository |
| Supporting tools | Git, curl, ripgrep, unzip, and xz |
| Background service | A systemd user service that starts at boot and survives logout |
| Network | T3 listens on `127.0.0.1`; remote access is enabled during T3 Connect sign-in |

The service's `PATH` includes the agent tools. Installer downloads use the user's
disk-backed cache instead of `/tmp`, which can be a small RAM disk on Ubuntu.
The script configures key-only SSH login for `t3`; other users' SSH policies stay
as configured on the droplet.

## Before you start

- Use a **fresh Ubuntu 26.04 droplet** with systemd and internet access.
- Select your **SSH key** when creating it. The script requires
  `/root/.ssh/authorized_keys` and preserves root access for administration.
- Allow inbound SSH and outbound HTTPS plus TCP/UDP port **7844** for the tunnel.
- Have a ChatGPT account with Codex access, a GitHub account, and a T3 Connect account
  ready for the interactive sign-in steps.

Very small droplets have little memory left for agents or builds. This script does
not resize the droplet or create swap; provision memory and disk for your workload.

## Install

Choose one installation method. Both run the script as root; the coding tools and
T3 service are installed under `t3`.

### During droplet creation

Paste the complete contents of
[`setup-agent-droplet.sh`](./setup-agent-droplet.sh) into DigitalOcean's **User data**
field when creating the droplet. Cloud-init runs it on the first boot.

Watch progress over SSH as root:

```bash
tail -f /var/log/cloud-init-output.log
```

### On an existing fresh droplet

From your computer, connect to the droplet:

```bash
ssh root@YOUR_DROPLET_IP
```

Download the script, review it, and run it:

```bash
curl -fsSL --retry 3 \
  https://raw.githubusercontent.com/bhurling/droplets/main/t3-server/setup-agent-droplet.sh \
  -o /root/setup-agent-droplet.sh
less /root/setup-agent-droplet.sh
bash /root/setup-agent-droplet.sh
```

The URL reads the `main` branch. Push your changes there before using the download
command. For a private repository, upload a local copy instead, then run it as root:

```bash
# Run from the repository root on your computer.
scp t3-server/setup-agent-droplet.sh root@YOUR_DROPLET_IP:/root/setup-agent-droplet.sh
ssh root@YOUR_DROPLET_IP 'bash /root/setup-agent-droplet.sh'
```

Both installation methods also write to `/var/log/t3-droplet-setup.log`.
Wait for **Setup complete** before continuing.

## Sign in and connect

Open a **new terminal on your computer** and SSH directly into the agent account:

```bash
ssh t3@YOUR_DROPLET_IP
```

Run all remaining commands in this session as `t3`, without `sudo`.

### 1. Connect Codex to ChatGPT

First enable **device-code sign-in** under **ChatGPT → Settings → Security**.
For a managed workspace, your administrator may need to allow it.

```bash
codex login --device-auth
```

Keep the SSH session open. Open the printed URL in your computer's browser, sign
in, and enter the code from the terminal. Wait for the terminal to confirm success.

```bash
codex login status
```

Expected: **Logged in using ChatGPT**. If you retry, cancel the old attempt with
Ctrl+C and use the new code. See [OpenAI's headless sign-in guide](https://learn.chatgpt.com/docs/auth#login-on-headless-devices).

### 2. Connect GitHub

```bash
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git
gh auth status
```

Complete the browser/device-code flow shown by `gh`. This configures HTTPS Git
authentication; your SSH key for droplet access is separate.

### 3. Enable T3 Connect

```bash
t3 connect link --headless
t3 service restart
t3 connect status
```

Approve the printed sign-in link using the **same T3 Connect account** as your
other devices. Accept installation of the managed relay client if prompted.
The restart applies the link. Startup can take a minute on a small droplet; repeat
`t3 connect status` until it reports **Other devices can reach this machine**.

In T3 Code on your other device, sign in to that account and select the droplet
under **Settings → Environments**. Under **Settings → Providers**, select the droplet
and refresh Codex's status. If it needs an explicit binary path, use
`/home/t3/.local/bin/codex`.

## Start working

Clone a repository on the droplet, for example:

```bash
cd ~/projects
gh repo clone OWNER/REPOSITORY
```

Add the cloned folder as a project in T3 Code with the droplet selected, then start
a Codex thread there. Authentication stays on this server; sign in separately on
each new droplet.

## Maintenance and recovery

Run these as `t3` over a direct SSH connection:

| Task | Command |
| --- | --- |
| Check the background service | `t3 service status` |
| Check remote reachability | `t3 connect status` |
| Repair service registration | `t3 service install` |
| Restart after a configuration change | `t3 service restart` |
| Update T3 Code | `t3 update` |
| Inspect the systemd unit | `systemctl --user status t3code.service` |
| Follow server logs | `tail -f ~/.t3/userdata/logs/boot-service.log` |

Restarts interrupt active agents, terminals, and remote connections. The script pins
T3 and Codex versions; change those pins intentionally when maintaining it. GitHub
CLI and the supporting tools follow Ubuntu's package versions.

### “Cannot reach the systemd user manager”

SSH **directly as `t3`** from your computer. A shell entered through `su` from root
may lack the user-session environment. If a direct login still fails, run the
following as root on the droplet:

```bash
loginctl enable-linger t3
systemctl start "user@$(id -u t3).service"
```

Open a fresh SSH session as `t3`, then run `t3 service install` and `t3 connect status`.
Do not run T3 with sudo: that creates a separate root installation and identity.

### The droplet's IP changed

Use the new IP for SSH, then check `t3 service status` and `t3 connect status`.
T3 Connect uses the droplet's outbound tunnel rather than a saved public IP; an
SSH route saved in your app must be updated separately. Restart the service if the
tunnel has not recovered. See [T3 Connect troubleshooting](https://github.com/pingdotgg/t3code/blob/main/docs/user/t3-connect-troubleshooting.md).

### Browser previews do not start

Ubuntu may require Chrome sandbox permissions and additional libraries. This script
does not install browser dependencies. Follow the host setup instructions shown by
T3's error message and the [browser host setup guide](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md#browser-host-setup).
An administrator must apply the system changes because `t3` has no sudo privileges;
keep the T3 server running as `t3`.

### Rerunning provisioning

The script preserves existing `t3` SSH keys and `~/.t3/service.env`, and repairs the
service registration. It reapplies the pinned tool versions and its SSH and systemd
drop-ins, so use it for provisioning or repair rather than routine updates. It
refuses an existing `t3` account with a different home/shell or privileged group
membership. It is intended for a dedicated agent host, not an already customized
multi-user server.
