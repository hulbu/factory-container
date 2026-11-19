# HulbuFactory container

HulbuFactory as a container. One `docker compose up` on a Linux machine you own (a VPS, a Raspberry Pi, a home
server) gives you a HulbuFactory **device**: it takes jobs from your organization on hulbu.com and runs coding agents
(Claude Code, Codex, pi) on them.

- **Light:** Debian 12 (slim) with git, bubblewrap, ca-certificates, GitHub's `gh` and Node. About 120 MB to download.
- **The HulbuFactory program is not in the image.** At the first start the container downloads it from
  releases.hulbu.com, checks its signature and checksums, and only then runs it. Every later start looks for a newer
  release and checks the installed program again.
- **Everything in one volume:** the program, your sign-ins, the agents, the work. `docker compose down -v` removes it.
- **No secret** in the image, the compose file or its environment. You sign in by hand, once.
- amd64 and arm64. Made for plain Docker, and meant to work with Coolify too (not tried yet).

## Status: first version, for trying it out

Read this before you install:

1. **releases.hulbu.com has no Linux build yet.** Until it has, the container says so and waits. You can practise
   with a build of your own (see [Practice with a local build](#practice-with-a-local-build)).
2. **No image is published yet.** You build it once yourself (see [Install](#install)). Never build on a Raspberry Pi:
   build on another machine and copy the image over.
3. **Taking jobs needs a HulbuFactory release that reads `HULBU_BINFMT_FOLDER`.** HulbuFactory runs each agent in its
   own sandbox (bubblewrap) and starts no job when that sandbox is not available. The compose file gives the container
   exactly what that sandbox needs (see [The agents' sandbox](#the-agents-sandbox)). HulbuFactory also checks the
   host's `binfmt_misc` handlers before it trusts its sandbox; the compose file shows it the host's list, read only, at
   `/run/host/binfmt_misc`, and the image names that folder in `HULBU_BINFMT_FOLDER`. A HulbuFactory build that does not
   read that variable yet still says "unavailable" on a host whose kernel has `binfmt_misc` (most do), and takes no
   job. `hulbu sandbox check` says which case you are in.

## What you need

- A Linux machine with an x86_64 (amd64) or aarch64 (arm64) processor, given to HulbuFactory alone. A Raspberry Pi 5
  with a 64-bit system is a first target, but not tried yet: its kernel uses 16 KB memory pages by default, and
  whether every program runs with them is still to be checked.
- Docker Engine with the Compose plugin (`docker compose version`).
- About 3 GB of free disk: about 350 MB for the image, about 2 GB in the volume before the first job (the program,
  the Claude driver, the agents), then the work itself. On a Raspberry Pi, put Docker's data on an SSD rather than the
  SD card.
- An account on hulbu.com in the organization the device will work for, a Claude account, and a GitHub account that
  has access only to the repositories the jobs need (never an organization owner's account).

## Prepare a Raspberry Pi (once)

On Raspberry Pi OS (64-bit) with Docker Engine installed from Docker's own package repository, these are the only
commands that need `sudo`:

```sh
sudo systemctl enable --now docker               # start Docker now and at every boot
sudo apt-get install -y docker-compose-plugin    # `docker compose`
sudo usermod -aG docker "$USER"                  # use Docker without sudo; then log out and back in
```

Membership of the `docker` group is as good as root on that machine; give it only to the person who runs
HulbuFactory. Then check, without `sudo`: `docker compose version`, `docker info`, and `sysctl user.max_user_namespaces`
(it must be more than 0; Raspberry Pi OS allows them). AppArmor is off on Raspberry Pi OS, so the AppArmor step below
does not apply. Everything after this runs as you, without `sudo`.

## Install

```sh
git clone https://github.com/hulbu/factory-container.git
cd factory-container
docker compose build          # on the machine itself, if it is not a Raspberry Pi
docker compose up -d
docker compose logs -f factory
```

**For a Raspberry Pi**, build the arm64 image on another machine (with Docker Buildx) and copy it over. On an x86
machine, Buildx needs arm64 emulation set up first (Docker Desktop has it; on Linux, see Docker's "multi-platform
builds"). An arm64 machine builds it directly.

```sh
docker buildx build --platform linux/arm64 -t hulbu-factory:local --output type=docker,dest=hulbu-factory-arm64.tar .
scp hulbu-factory-arm64.tar pi@your-pi:            # then, on the Pi:
docker load -i hulbu-factory-arm64.tar
docker compose up -d --no-build                     # in a clone of this repository on the Pi; never builds there
```

## The agents' sandbox

Each agent runs in its own sandbox (bubblewrap) inside the container: it sees only its own job's folder and the
system's programs, not the sign-ins or the other jobs. Bubblewrap needs an unprivileged user namespace, which Docker's
default settings refuse. `docker-compose.yml` therefore adds exactly this, and nothing more:

- **`seccomp=./profiles/seccomp.json`**: Docker's default seccomp profile plus one rule allowing `clone` and `unshare`
  with namespace flags, `mount`, `umount2` and `pivot_root`. Docker normally allows them only with `CAP_SYS_ADMIN`;
  this container has **no capability at all** (`cap_drop: [ALL]`), so these calls work only inside the namespaces
  bubblewrap makes, not on the container's own mounts. `profiles/make-seccomp.sh` rebuilds the file from Docker's
  profile, pinned by commit and checksum.
- **`systempaths=unconfined`**: bubblewrap mounts a fresh `/proc` for each agent, and the kernel allows that only when
  the container's `/proc` is not partly hidden. This removes both of Docker's lists: the **masked** paths (files it
  hides: `/proc/kcore`, `/proc/keys`, `/proc/timer_list`, `/sys/firmware` and others) and the **read-only** paths
  (`/proc/sys`, `/proc/sysrq-trigger`, `/proc/irq`, `/proc/bus` and others). **Rule: this is safe only because the
  container never runs as root and holds no capability** (`user: "10001:10001"`, `cap_drop: [ALL]`): the kernel then
  refuses writes to those files anyway. Never add a capability, `--privileged` or `user: root` to this file.
- **`/proc/sys/fs/binfmt_misc:/run/host/binfmt_misc:ro`**: the host's `binfmt_misc` handler list, read only. A handler
  can make Linux run a program outside every sandbox (an emulator, or a tool that forwards programs to another
  machine), so HulbuFactory reads this list before it trusts its sandbox, and refuses when it cannot. The list holds
  no data, only the handlers' names, magic bytes and interpreters; with no capability the container cannot change it.
  On a host where systemd mounts `binfmt_misc` only when it is first used, run `ls /proc/sys/fs/binfmt_misc` once
  before `docker compose up`, or the container may see an empty folder (and the check then refuses).
- Kept from before: `no-new-privileges`, `cap_drop: [ALL]`, a read-only root, user 10001. Never `--privileged`, never
  the Docker socket. This bind is the only host folder the container gets.

**On a host with AppArmor on** (`cat /sys/module/apparmor/parameters/enabled` says `Y`: Debian, Ubuntu; not
Raspberry Pi OS), Docker's own AppArmor profile refuses every mount. Load this repository's profile once, as root, and
start with the extra file:

```sh
sudo install -m 644 profiles/apparmor/hulbu-factory /etc/apparmor.d/hulbu-factory   # loads again at every boot
sudo apparmor_parser -r -W /etc/apparmor.d/hulbu-factory
docker compose -f docker-compose.yml -f docker-compose.apparmor.yml up -d
```

The profile is Docker's own with three changes, each marked in the file: mounts and `pivot_root`, `userns`, and
writes to `/proc/sys/user/` (for bubblewrap's `--disable-userns`). It needs AppArmor 4 (Debian 13, Ubuntu 24.04). To
remove it: `sudo apparmor_parser -R /etc/apparmor.d/hulbu-factory && sudo rm /etc/apparmor.d/hulbu-factory`.

**What giving the container user namespaces costs.** Docker refuses them by default for a reason. Inside a user
namespace a program is "root" of its own small world, and with that it can reach kernel code that ordinary programs
never reach: file systems it may mount, network and other namespaces it may make. Most bugs that let a local
program become root of the whole machine are found in exactly that code. With this compose file, an agent that has
escaped its sandbox (or any program in the container) can try those bugs; one that works makes it root on the host,
with everything on the machine. That is why HulbuFactory needs a machine that runs nothing else, kept up to date
(kernel updates and reboots), and never a shared server. An agent that escapes its sandbox reaches everything in the container
(the sign-ins, every job's folder); after anything suspicious, remove the device and the volume and install again.

## The device's name

hulbu.com shows the device under the name it had at its **first** `hulbu login`: the container's hostname. The compose
file sets it to `hulbufactory`; to choose your own, set it before you sign in:

```sh
echo 'HULBU_FACTORY_NAME=pi' >.env       # next to docker-compose.yml; Compose reads it by itself
docker compose up -d
```

A name only letters, digits and `-` (it is a hostname). `hulbu login --name <name>` also sets the name at sign-in,
whatever the hostname is.

**Renaming a device that is already signed in** is not possible yet: the name is sent once, at sign-in, and there is no
rename on hulbu.com or in `hulbu`. To change it now, sign in again with the new name: Remove the device on hulbu.com,
then

```sh
docker compose exec -it factory hulbu logout
docker compose exec -it factory hulbu login --name pi
```

The Claude and GitHub sign-ins in the volume stay.

## Sign in (once)

All three sign-ins happen in the container, by hand. Nothing is typed into a file or a variable.

```sh
docker compose exec -it factory hulbu login
```

It shows a code. Open **hulbu.com/device**, enter the code and choose your organization.

```sh
docker compose exec -it factory hulbu accounts add claude --name claude-server
```

Claude prints a sign-in link. Open it, sign in, and paste the code it gives you back into the terminal.

```sh
docker compose exec -it factory gh auth login --web
```

It shows a code for github.com/login/device. Use a GitHub account that can reach only the repositories the jobs need.

Then check:

```sh
docker compose exec factory hulbu status
```

## What happens at each start

1. **The program.** The container fetches the signed list of the newest HulbuFactory release
   (`https://releases.hulbu.com/hulbufactory/cli/manifest.json` and its `.minisig`). It checks the signature before it
   reads anything, with the two Hulbu release keys built into the image (`keys/`): key ids `D475C9BD9742B5CF` and
   `8F9BF929B7E0A5F5`. Then it checks the release itself: the stable channel, a version no older than one this machine
   already had, and both files on releases.hulbu.com with a size and a SHA-256. When the installed files are exactly
   the listed ones, they run. Otherwise both files are downloaded, each checked against its size and SHA-256, run
   once (`hulbu version --json`) and installed. It keeps the signed list, so a later start without network can check
   the installed program against it. **Nothing that fails a check is ever run.**
2. **The coding agents.** Claude Code, Codex and pi are each installed with npm into their own folder in the volume,
   at their latest release. After that, Claude Code updates itself with its own updater (not tried yet in this
   container). Codex and pi do not update themselves: they stay at the version first installed until you remove their
   folder (`docker compose exec factory rm -rf .local/share/hulbu-factory/agents/codex`, then `docker compose
   restart`), which installs the newest release again. npm uses the public registry and checks
   each package's integrity and the registry's signatures. An agent that cannot be installed is named in the log;
   the others are not affected, and it is tried again at the next start. To pin them instead, see
   [Pinning the agents](#pinning-the-agents).
3. **`hulbu run`** starts and stays the container's main process.

The check runs at **every** start, not only the first, and once more just before `hulbu run` (against the release
as it was accepted, kept in memory), so a HulbuFactory program changed inside the volume is replaced by the signed one
at the next start. **Only those two files are checked again**, and a program left running by an agent's install
script could still change them between that last check and the start. Everything else in the volume (the agents, the sign-ins, git's and gh's settings, the work) is not, so after
anything suspicious, do not clean up in place: remove the device on the server side and the volume, and install
again (see [Removing it](#removing-it)).

When it cannot go on, the log says why, in one sentence:

| What happened                                                | What the container does                                                 |
| ------------------------------------------------------------ | ----------------------------------------------------------------------- |
| No network at a later start                                  | checks the installed program against the signed list kept from the last good start, says the update check was skipped, and starts it |
| No network at the first start                                | says so and tries again every minute                                    |
| Something does not match its signed list                     | installs nothing new; starts the program installed before (checked again against its own kept list), or with none, tries again in 5 minutes; a release may be mid-publish |
| It keeps not matching (more than 12 times in a row)          | the same, and asks you to report it                                     |
| releases.hulbu.com has no build for this machine             | at the first start: says so, points here, and tries again in an hour; later: starts the program checked earlier, as with no network |
| A newer release does not run on this machine                | does not install it; starts the program installed before, or with none, tries again in an hour |

## Pinning the agents

For a fixed setup (for example to compare agents or models), the agents can be installed at exact versions instead:
Claude Code at the version the HulbuFactory release names (the one its Claude driver uses), Codex and pi at the
versions the release was tested with, otherwise at the versions in `entrypoint/agents.json`. Claude Code's own
updater is then turned off. Create `docker-compose.override.yml` next to `docker-compose.yml` (Compose reads it by
itself):

```yaml
services:
  factory:
    environment:
      HULBU_FACTORY_AGENTS: pinned
```

Then `docker compose up -d`. Remove the file to go back to the agents' normal updates.

## After a reboot

The container comes back by itself when the machine restarts: `restart: unless-stopped` in the compose file, and Docker
started at boot (`sudo systemctl enable docker`, in [Prepare a Raspberry Pi](#prepare-a-raspberry-pi-once)). It stays
down only if you stopped it yourself (`docker compose stop`); `docker compose up -d` starts it again.

`hulbu status` inside the container says **`Autostart: off`**. That is expected: it describes HulbuFactory's own
service manager (systemd or launchd), which the container does not use. Docker's restart policy does that job here.

## Updating

- **HulbuFactory:** `docker compose restart`. Each start installs the newest signed release when releases.hulbu.com
  can be reached.
- **The agents:** Claude Code updates itself; Codex and pi are updated by removing their folder and restarting (see
  [What happens at each start](#what-happens-at-each-start)); pinned agents follow the pin.
- **The image** (Debian's security updates, Node, gh): `git pull`, `docker compose build`, `docker compose up -d`.
  Rebuild it about once a week.

## Practice with a local build

Until releases.hulbu.com has Linux builds, you can run HulbuFactory programs you built yourself. **This is for
practice: they are not signed**, and the container checks them only against the SHA-256 values you give.

1. Build `hulbu` and `station-driver-claude` for this machine (`linux-x64` or `linux-arm64`) and for glibc 2.36 or
   older (the image is Debian 12), for example with `cargo zigbuild` for `…-unknown-linux-gnu.2.28`.
2. Put both files in a folder `practice/` next to `docker-compose.yml`, and compute their checksums:

   ```sh
   sha256sum practice/hulbu practice/station-driver-claude
   ```

3. Put the two values into `docker-compose.practice.yml`, then start with both files:

   ```sh
   docker compose -f docker-compose.yml -f docker-compose.practice.yml up -d
   ```

The log says "Practice build, not signed" at every start. When a checksum does not match, the container starts
nothing and says which file. To go back to the signed release, start with `docker compose up -d` alone.

## Coolify

Coolify takes **one** compose file: use `docker-compose.coolify.yml`. It holds everything the other files give (the
seccomp and AppArmor profiles, the binfmt list, the practice volume), plus firm limits for a machine that runs other
work: 4 CPUs at a low weight, 8 GB with no swap, 4096 processes, its own network, no port published.

**On the host first** (once, as an administrator):

1. The AppArmor profile, installed so it loads again at every boot. **Required** on Ubuntu 24.04 and other AppArmor
   hosts: without it, user namespaces are refused and no agent starts (and after a reboot the container would not
   start at all):

   ```sh
   sudo install -m 644 profiles/apparmor/hulbu-factory /etc/apparmor.d/hulbu-factory
   sudo apparmor_parser -r -W /etc/apparmor.d/hulbu-factory
   ```
2. The image, loaded by hand (Coolify never builds or pulls it): `gunzip -c hulbu-factory-amd64.tar.gz | docker load`.
3. `docker volume create hulbu-factory-practice` (empty unless you practise with a build of your own).
4. The network fence: see [A fence on a shared machine](#a-fence-on-a-shared-machine).

**In Coolify** (the names are Coolify 4's; they may differ a little in other versions):

1. Your project → **+ New** → **Public Repository** → `https://github.com/hulbu/factory-container`, branch `main`.
2. **Build Pack: Docker Compose**, Base Directory `/`, Docker Compose Location `/docker-compose.coolify.yml`.
3. The service `factory`: **no domain**. **Connect To Predefined Network: off** (so it never joins Coolify's shared
   network). No port.
4. Environment variables (none is a secret): `HULBU_FACTORY_NAME`, and only if you want other limits
   `HULBU_FACTORY_CPUS`, `HULBU_FACTORY_MEMORY`.
5. **Deploy**. Then the resource's **Terminal**, container `factory`: the three commands of
   [Sign in](#sign-in-once) (without `docker compose exec -it factory`).

To remove it: the server-side steps of [Removing it](#removing-it), then delete the resource **and its volumes** in
Coolify, the image, the fence and the AppArmor profile.

## A fence on a shared machine

On a machine that runs other work (Coolify's apps, databases, CI), the container must not reach them. With
`docker-compose.coolify.yml` it has its own subnet, `172.30.86.0/24`, and `profiles/fence/` holds rules for that
subnet: no other Docker network or private network (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16), no tailnet
(100.64.0.0/10), no cloud metadata (169.254.0.0/16), no mail ports, and no new connection to the host itself. A systemd
unit loads them **before Docker starts** at boot (so the container is never up unfenced), and a second one again after
every Docker start. They match the subnet, so a redeploy that renames the network keeps them.

```sh
sudo install -m 755 profiles/fence/hulbu-factory-fence /usr/local/sbin/
sudo install -m 644 profiles/fence/hulbu-factory-fence.service profiles/fence/hulbu-factory-fence-again.service \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hulbu-factory-fence.service hulbu-factory-fence-again.service
sudo iptables -S DOCKER-USER | grep -c hulbu-factory    # 6
sudo iptables -S INPUT | grep -c hulbu-factory          # 1
```

**Check it**, from inside the container, after the first deploy, after `sudo systemctl restart docker`, and after
every redeploy: each line must say `refused` except the last, `https://api.hulbu.com`.

```sh
node -e '
const net = require("net");
const tcp = (host, port) => new Promise(done => { const s = net.connect({ host, port, timeout: 3000 });
  s.on("connect", () => { s.destroy(); done(`${host}:${port} REACHED`); });
  s.on("timeout", () => { s.destroy(); done(`${host}:${port} refused`); }); s.on("error", () => done(`${host}:${port} refused`)); });
(async () => {
  for (const [host, port] of [["169.254.169.254", 80], ["10.0.0.1", 80], ["172.17.0.1", 80], ["192.168.1.1", 80],
                              ["172.30.86.1", 22], ["smtp.gmail.com", 25]]) console.log(await tcp(host, port));
  const r = await fetch("https://api.hulbu.com", { signal: AbortSignal.timeout(5000) }).catch(e => null);
  console.log("https://api.hulbu.com", r ? "REACHED " + r.status : "refused (must be REACHED)");
})();'
```

Add your own host's addresses and ports to the list (its LAN address, the gateway of another app's network).
Undo: `sudo systemctl disable --now hulbu-factory-fence.service hulbu-factory-fence-again.service`, remove the three
installed files, and delete each
`hulbu-factory` rule by its comment (`sudo iptables -S DOCKER-USER`, `sudo iptables -S INPUT`, then `-D`).

## Removing it

**First on the server side**, so nothing can be used after the machine is gone (this works even if the machine is
already gone):

1. On hulbu.com, open your organization's devices and **Remove** this device. Its sign-in stops working at once.
2. On GitHub, revoke the GitHub CLI's authorization for the account you signed in with (Settings → Applications).
3. Claude: end the sign-in you made for this device. Whether claude.ai can end one Claude Code sign-in on its own is
   not checked yet; if it cannot, use a Claude account only for this device and sign it out everywhere.

**Then on the machine:**

```sh
docker compose down -v               # the container, its network and the volume (program, sign-ins, agents, work)
docker image rm hulbu-factory:local  # the image
```

`docker compose down -v` removes everything on the machine, but not the records on hulbu.com, GitHub and claude.ai:
that is what the three steps above are for. Then delete this folder.

## What is in the image

| Part                                         | From                                               | amd64 on disk | arm64 on disk |
| -------------------------------------------- | -------------------------------------------------- | ------------- | ------------- |
| Debian 12 slim                               | `debian:bookworm-slim`, pinned by digest           | 75 MB         | 97 MB         |
| git (with the Perl it needs), bubblewrap, ca-certificates | Debian                                | 94 MB         | 97 MB         |
| gh                                           | GitHub's Debian repository (its key is in `keys/`) | 42 MB         | 39 MB         |
| Node 24 (without its C headers and docs)     | nodejs.org, checked against a pinned SHA-256       | 140 MB        | 137 MB        |
| the entrypoint, the release check, the keys  | this repository                                    | under 0.1 MB  | under 0.1 MB  |
| **Total on disk**                            |                                                    | **334 MB**    | **353 MB**    |
| **Download (compressed)**                    |                                                    | **about 119 MB** | **about 117 MB** |

Measured by this repository's CI on 2026-11-18 (`docker history`; the download size is a gzip of `docker save`).

Not in the image: the HulbuFactory program, the coding agents, any token, key, password or sign-in, SSH, Docker,
Rust or a compiler. The container never needs `--privileged` or the Docker socket.

## Checking this repository

```sh
node --test test/verify-release.test.mjs   # the release check, with test keys and one real signed release list
bash test/start.test.sh                     # the entrypoint, without Docker (needs GNU mv, as gmv on macOS)
shellcheck entrypoint/start.sh bin/hulbu test/start.test.sh
docker compose config -q
```

## Reporting a problem

Open an issue in this repository. For a signature or checksum that keeps failing, say so in the title.

## License

Not chosen yet. Until a license file is added, no license is granted.
