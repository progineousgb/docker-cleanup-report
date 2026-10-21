# docker-cleanup-report

```sh
curl -fsSL https://raw.githubusercontent.com/progineousgb/docker-cleanup-report/main/docker-cleanup-report.sh | sudo bash
```

Your disk is full and Docker is probably why. This script shows where the space went, sorts what can go into safe and risky, and prints the commands to remove it. It never deletes anything itself. You read the list, you run the command.

## Example output

Real run against Docker 29.1.4 on a test machine with a few leftover containers, a rebuilt image and two orphan volumes.

```
$ ./docker-cleanup-report.sh

docker-cleanup-report 1.0.0  Docker 29.1.4, data in /var/lib/docker
Read-only. Nothing below has been run.

== Space used ==
  TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
  Images          6         3         261.8MB   20.27MB (7%)
  Containers      3         1         0B        0B
  Local Volumes   2         0         20.97MB   20.97MB (100%)
  Build Cache     0         0         0B        0B

== Dangling images (safe) ==
  1 untagged image layer(s) left over from rebuilds or pulls:
    c368514980a3  7.4MB  created 22 seconds ago
  Remove them:
    $ docker image prune

== Images not used by any container (usually safe) ==
  2 tagged image(s) with no container. They can be pulled again later, but
  a local-only build you did not push would be lost:
    myapp:dev                                          7.4MB  created 21 seconds ago
    moby/buildkit:v0.29.0                              241MB  created 6 months ago
  Remove all images not used by a container:
    $ docker image prune -a
  Or only those older than a week:
    $ docker image prune -a --filter "until=168h"

== Stopped containers (safe if you do not need them) ==
  2 stopped container(s). Their writable layer and anything not in a volume goes with them:
    never-started            busybox              Created                        0B (virtual 4.45MB)
    old-job                  alpine:3.19          Exited (0) 35 seconds ago      0B (virtual 7.4MB)
  Remove all stopped containers:
    $ docker container prune

== Unused volumes (RISKY, check first) ==
  2 volume(s) not attached to any container. Volumes hold data such as
  databases and uploads. Docker cannot tell if you still need it, so look before you delete.
    4847281109c0c4f9e62689d558e79e32dbce4d1eb2d50b498ae84fb2a17af87e   0B
    pgdata-old                                                         20.97MB
  Look inside one first:
    $ docker run --rm -v 4847281109c0c4f9e62689d558e79e32dbce4d1eb2d50b498ae84fb2a17af87e:/v alpine ls -la /v
  Remove one you are sure about:
    $ docker volume rm 4847281109c0c4f9e62689d558e79e32dbce4d1eb2d50b498ae84fb2a17af87e
  Remove anonymous unused volumes (named ones are kept on Docker 23+):
    $ docker volume prune

== Build cache (safe, rebuilds get slower once) ==
  Empty.

== Container logs ==
  Run with sudo on the Docker host to check container log sizes.

== All at once ==
  Removes stopped containers, unused networks, dangling images and build cache.
  Volumes are kept unless you add --volumes:
    $ docker system prune

Nothing was deleted. Review the lists above before running any command.
```

## What it checks

- **Space used**: `docker system df`, plus `du` of the Docker data directory when it is readable.
- **Dangling images**: untagged layers left by rebuilds. Safe to remove.
- **Images with no container**: tagged images that no container (running or stopped) uses. Usually safe, but an image you built locally and never pushed is gone for good.
- **Stopped containers**: exited, created or dead containers, with their size.
- **Unused volumes**: volumes with no container attached, with sizes. Marked as risky, because this is where databases live. It shows how to look inside one before deleting it.
- **Build cache**: size and reclaimable amount.
- **Container logs**: json-file logs over 10 MB (needs root on the Docker host), how to truncate one, and the `daemon.json` setting to cap them.

## Options

```
-n, --top N     rows per list (default 10)
--no-color      plain text
-h, --help
-V, --version
```

It uses the normal `docker` CLI, so `DOCKER_HOST` and docker contexts work. Podman with the docker CLI shim should work but has not been tested.

## Limits

- Needs the docker CLI and access to the daemon (root or the docker group).
- The log size check reads files under the Docker data dir, so it only works when you run it with sudo on the Docker host itself.
- Build cache is what `docker system df` reports for the default builder. Other buildx builders are not counted.
- "Not used by any container" means right now. A cron job or compose file that starts a container later may still need that image.

## Maintained by

Maintained by Pro Gineous, a domains, hosting and VPS provider: https://progineous.com

Issues and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE).
