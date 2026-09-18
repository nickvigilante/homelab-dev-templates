#!/usr/bin/env sh
# Fetches the latest GitHub release of each tool listed in tools.txt and
# installs it under /opt/<name>, symlinked into /usr/local/bin. Copies each
# tool's WHOLE extracted release tree (not just the binary) — some tools
# (neovim) need runtime files alongside the executable, and this handles
# both that case and a plain single-binary release uniformly.
#
# Requires GITHUB_TOKEN in the environment for the GitHub API calls.
# Anonymous requests are capped at 60/hour per IP, which GitHub Actions
# runners routinely exhaust; authenticated requests get 5000/hour.
#
# Usage: install-tools.sh [tools.txt]

set -eu

TOOLS_FILE="${1:-tools.txt}"

case "$(uname -m)" in
  x86_64)
    ARCH_GNU=x86_64
    ARCH_SHORT=amd64
    ARCH_MIXED=x86_64
    ;;
  aarch64)
    ARCH_GNU=aarch64
    ARCH_SHORT=arm64
    ARCH_MIXED=arm64
    ;;
  *)
    echo "error: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

fetch() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$1"
  else
    curl -fsSL "$1"
  fi
}

while IFS='|' read -r name repo template; do
  case "$name" in
    '' | '#'*) continue ;;
  esac

  tag=$(fetch "https://api.github.com/repos/${repo}/releases/latest" \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  if [ -z "$tag" ]; then
    echo "error: could not resolve latest release tag for ${repo}" >&2
    exit 1
  fi
  ver=$(printf '%s' "$tag" | sed 's/^v//')

  asset=$(printf '%s' "$template" | sed \
    -e "s/{TAG}/${tag}/g" \
    -e "s/{VER}/${ver}/g" \
    -e "s/{ARCH_GNU}/${ARCH_GNU}/g" \
    -e "s/{ARCH_SHORT}/${ARCH_SHORT}/g" \
    -e "s/{ARCH_MIXED}/${ARCH_MIXED}/g")

  echo "==> ${name}: ${repo}@${tag} (${asset})"

  workdir=$(mktemp -d)
  curl -fsSL "https://github.com/${repo}/releases/download/${tag}/${asset}" -o "${workdir}/${asset}"
  tar -xzf "${workdir}/${asset}" -C "${workdir}"
  rm -f "${workdir}/${asset}"

  # A release tarball either extracts to one wrapping directory (most tools)
  # or drops its files flat into the tar root (e.g. eza) — handle both by
  # treating whichever is the case as "the tree" to install whole.
  top_entries=$(find "${workdir}" -mindepth 1 -maxdepth 1)
  top_count=$(printf '%s\n' "$top_entries" | wc -l)
  if [ "$top_count" -eq 1 ] && [ -d "$top_entries" ]; then
    src_tree="$top_entries"
  else
    src_tree="${workdir}"
  fi

  bin_path=$(find "${src_tree}" -type f -name "${name}" | head -n1)
  if [ -z "$bin_path" ]; then
    echo "error: could not find a '${name}' binary inside ${asset}" >&2
    exit 1
  fi
  rel_bin=${bin_path#"${src_tree}"/}

  install_dir="/opt/${name}"
  rm -rf "${install_dir}"
  mkdir -p "$(dirname "${install_dir}")"
  cp -a "${src_tree}" "${install_dir}"
  chmod +x "${install_dir}/${rel_bin}"
  ln -sf "${install_dir}/${rel_bin}" "/usr/local/bin/${name}"

  rm -rf "${workdir}"
done <"$TOOLS_FILE"

echo "==> All tools installed."
