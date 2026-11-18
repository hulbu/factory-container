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
3. **It does not take jobs yet.** HulbuFactory runs each agent in its own sandbox and starts no job when that sandbox
   is not available. Inside a container with Docker's normal settings, it is not, and how the sandbox should work in
   a container is still being decided. Until then this version installs, signs in and shows its status, and takes no
   job.

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

Not tried yet. The plan: create a **Docker Compose** resource from this repository, pointing it at
`docker-compose.yml`, with no environment variable to set. Then open a terminal in the `factory` container (from
Coolify, or `docker exec -it <container> bash` on the server) and run the three commands of [Sign in](#sign-in-once).
To remove it, delete the resource **and its volume**, after the server-side steps of [Removing it](#removing-it).

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
