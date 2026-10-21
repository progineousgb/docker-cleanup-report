#!/usr/bin/env bash
# docker-cleanup-report - see where Docker disk space goes and what is safe to remove.
# Maintained by Pro Gineous (https://progineous.com). MIT licensed.
# Read-only: this script never deletes anything. It prints commands for you to run.
set -euo pipefail

VERSION="1.0.0"
COLOR=1
TOP=10

usage() {
  cat <<USAGE
docker-cleanup-report $VERSION
Shows how much space Docker uses (images, containers, volumes, build cache),
what can be removed, and the exact commands to remove it. Never deletes anything.

Usage: docker-cleanup-report.sh [options]

Options:
  -n, --top N     Rows per list (default $TOP)
  --no-color      Plain output (also honoured: NO_COLOR)
  -h, --help      Show this help
  -V, --version   Show version

Uses the normal docker CLI, so DOCKER_HOST and docker contexts are respected.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--top) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "--top needs a number" >&2; exit 2; }; TOP=$2; shift ;;
    --no-color) COLOR=0 ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "docker-cleanup-report $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

[[ -n "${NO_COLOR:-}" || ! -t 1 ]] && COLOR=0
if [[ $COLOR -eq 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; C=$'\e[36m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; D=""; C=""; N=""
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI not found. Nothing to report." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Cannot talk to the Docker daemon. Try sudo, or check that docker is running (systemctl status docker)." >&2
  exit 1
fi

section() { printf '\n%s%s== %s ==%s\n' "$B" "$C" "$1" "$N"; }
say() { printf '  %s\n' "$*"; }
cmd() { printf '    %s$ %s%s\n' "$C" "$*" "$N"; }

ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "?")
printf '\n%sdocker-cleanup-report %s%s  %sDocker %s, data in %s%s\n' "$B" "$VERSION" "$N" "$D" "$ver" "$root" "$N"
printf '%sRead-only. Nothing below has been run.%s\n' "$D" "$N"

section "Space used"
docker system df 2>/dev/null | sed 's/^/  /'
if [[ -d "$root" && -r "$root" ]] && command -v du >/dev/null 2>&1; then
  say "On disk: $(du -sh "$root" 2>/dev/null | awk '{print $1}') in $root (includes logs and overlay data)."
fi

# ---- dangling images ----
section "Dangling images (safe)"
mapfile -t dangling < <(docker images -f dangling=true --format '{{.ID}}  {{.Size}}  created {{.CreatedSince}}' 2>/dev/null)
if [[ ${#dangling[@]} -eq 0 ]]; then
  say "${G}None.${N}"
else
  say "${#dangling[@]} untagged image layer(s) left over from rebuilds or pulls:"
  printf '%s\n' "${dangling[@]}" | head -n "$TOP" | sed 's/^/    /'
  say "Remove them:"
  cmd "docker image prune"
fi

# ---- unused images ----
section "Images not used by any container (usually safe)"
used_ids=$(docker ps -a --format '{{.Image}}' 2>/dev/null | sort -u | while read -r ref; do
  docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true; done | sort -u)
unused=()
seen_ids=" "
while read -r id repo size since; do
  [[ -z "$id" ]] && continue
  [[ "$repo" == *":<none>" ]] && continue
  [[ "$seen_ids" == *" $id "* ]] && continue
  seen_ids+="$id "
  full=$(docker image inspect --format '{{.Id}}' "$id" 2>/dev/null || true)
  grep -qxF "$full" <<<"$used_ids" && continue
  [[ "$repo" == "<none>:<none>" ]] && continue
  unused+=("$(printf '%-45s %10s  created %s' "$repo" "$size" "$since")")
done < <(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Size}} {{.CreatedSince}}' 2>/dev/null)
if [[ ${#unused[@]} -eq 0 ]]; then
  say "${G}None. Every tagged image is used by a container.${N}"
else
  say "${#unused[@]} tagged image(s) with no container. They can be pulled again later, but"
  say "a local-only build you did not push would be lost:"
  printf '%s\n' "${unused[@]}" | head -n "$TOP" | sed 's/^/    /'
  say "Remove all images not used by a container:"
  cmd "docker image prune -a"
  say "Or only those older than a week:"
  cmd "docker image prune -a --filter \"until=168h\""
fi

# ---- stopped containers ----
section "Stopped containers (safe if you do not need them)"
mapfile -t stopped < <(docker ps -a --filter status=exited --filter status=created --filter status=dead \
  --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Size}}' 2>/dev/null)
if [[ ${#stopped[@]} -eq 0 ]]; then
  say "${G}None.${N}"
else
  say "${#stopped[@]} stopped container(s). Their writable layer and anything not in a volume goes with them:"
  printf '%s\n' "${stopped[@]}" | head -n "$TOP" | awk -F'|' '{printf "    %-24s %-20s %-30s %s\n", $1, $2, $3, $4}'
  say "Remove all stopped containers:"
  cmd "docker container prune"
fi

# ---- volumes ----
section "Unused volumes (RISKY, check first)"
mapfile -t dvols < <(docker volume ls -qf dangling=true 2>/dev/null)
if [[ ${#dvols[@]} -eq 0 ]]; then
  say "${G}None.${N}"
else
  say "${R}${#dvols[@]} volume(s) not attached to any container. Volumes hold data such as"
  say "databases and uploads. Docker cannot tell if you still need it, so look before you delete.${N}"
  vsizes=$(docker system df -v 2>/dev/null | awk '/^Local Volumes space usage/ {f=1; next} /^Build cache/ {f=0} f && NF==3 && $1!="VOLUME" {print $1, $3}')
  for v in "${dvols[@]:0:$TOP}"; do
    sz=$(awk -v v="$v" '$1==v {print $2}' <<<"$vsizes")
    printf '    %-66s %s\n' "$v" "${sz:-?}"
  done
  say "Look inside one first:"
  cmd "docker run --rm -v ${dvols[0]}:/v alpine ls -la /v"
  say "Remove one you are sure about:"
  cmd "docker volume rm ${dvols[0]}"
  say "Remove anonymous unused volumes (named ones are kept on Docker 23+):"
  cmd "docker volume prune"
fi

# ---- build cache ----
section "Build cache (safe, rebuilds get slower once)"
bc=$(docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '$1=="Build Cache" {print $2" total, "$3" reclaimable"}')
if [[ -z "$bc" || "$bc" == 0B* ]]; then
  say "${G}Empty.${N}"
else
  say "$bc"
  cmd "docker builder prune"
  say "Keep the last week:"
  cmd "docker builder prune --filter \"until=168h\""
fi

# ---- container logs ----
section "Container logs"
if [[ $(id -u) -eq 0 && -d "$root/containers" ]]; then
  logs=$(find "$root/containers" -name '*-json.log' -size +10M -printf '%s %p\n' 2>/dev/null | sort -rn | head -n "$TOP" || true)
  if [[ -z "$logs" ]]; then
    say "${G}No json log file over 10 MB.${N}"
  else
    say "${Y}Large log files (they grow forever unless log rotation is set):${N}"
    while read -r size path; do
      cid=$(basename "$(dirname "$path")")
      name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || echo "${cid:0:12}")
      printf '    %8s MB  %s\n' "$((size / 1048576))" "$name"
    done <<<"$logs"
    say "Empty a log without stopping the container:"
    cmd "sudo truncate -s 0 \$(docker inspect --format '{{.LogPath}}' <container>)"
  fi
  say "Cap logs for new containers in /etc/docker/daemon.json, then restart docker:"
  say "${D}  {\"log-driver\": \"json-file\", \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"}}${N}"
else
  say "${D}Run with sudo on the Docker host to check container log sizes.${N}"
fi

section "All at once"
say "Removes stopped containers, unused networks, dangling images and build cache."
say "Volumes are kept unless you add --volumes:"
cmd "docker system prune"
printf '\n%sNothing was deleted. Review the lists above before running any command.%s\n\n' "$D" "$N"
