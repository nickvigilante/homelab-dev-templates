#!/usr/bin/env bash
# install-arc-runner — install actions-runner-controller and a runner scale set
# for nickvigilante/homelab-dev-templates, so template-push.yml has somewhere
# to run.
#
# Run from a machine with cluster admin access and helm + kubectl on PATH.
#
# The GitHub credential is read from the terminal, never from an argument:
# anything in argv lands in shell history and is visible in `ps`.
#
# Resolves https://github.com/nickvigilante/homelab-dev-templates/issues/25

set -euo pipefail

REPO_URL="https://github.com/nickvigilante/homelab-dev-templates"
CONTROLLER_NS="arc-systems"
RUNNER_NS="arc-runners"
SCALE_SET="arc-runner-set"
CODER_HEALTHZ="https://coder.vigihome.net/healthz"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
step() { printf '\n==> %s\n' "$*"; }

missing=""
for cmd in helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
if [ -n "$missing" ]; then
  cat >&2 <<EOF
error: not on PATH:$missing

Both are single binaries; no package manager needed:

  kubectl:
    curl -sLo ~/.local/bin/kubectl \\
      "https://dl.k8s.io/release/\$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x ~/.local/bin/kubectl

  helm:
    curl -sL https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz | tar xz -C /tmp
    install -m755 /tmp/linux-amd64/helm ~/.local/bin/helm
EOF
  exit 1
fi

# The dotfiles deploy the homelab kubeconfig to a fixed path, so fall back to
# it rather than making the caller export KUBECONFIG. Only when nothing is set:
# an explicit KUBECONFIG always wins, so this cannot silently retarget a
# cluster someone deliberately selected.
if [ -z "${KUBECONFIG:-}" ] && [ -f "$HOME/.kube/homelab.yaml" ]; then
  export KUBECONFIG="$HOME/.kube/homelab.yaml"
  printf 'Using KUBECONFIG=%s\n' "$KUBECONFIG"
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  cat >&2 <<EOF
error: kubectl cannot reach a cluster.

  KUBECONFIG=${KUBECONFIG:-<unset>}

The homelab API server is published on the tailnet as
gandalf.tail395fc0.ts.net:6443, so reaching it needs BOTH:

  1. Tailscale connected        -- check with: tailscale status
  2. KUBECONFIG pointing at the homelab config
       export KUBECONFIG=~/.kube/homelab.yaml

If ~/.kube/homelab.yaml is absent: chezmoi deploys it only where a Bitwarden
vault is configured, so run chezmoi apply with bw unlocked.
EOF
  exit 1
fi

printf 'Cluster context: %s\n' "$(kubectl config current-context)"

# ── The GitHub credential ────────────────────────────────────────────────────
#
# Use a FINE-GRAINED PAT scoped to this repository only, with
# Administration: read & write. A classic `repo`-scoped token also works, but
# grants access to every repository you own -- and this value is stored in a
# Kubernetes secret, so its blast radius is whatever the token can reach.
#
# Create at: https://github.com/settings/personal-access-tokens/new
#   Repository access : Only select repositories -> homelab-dev-templates
#   Permissions       : Repository -> Administration -> Read and write
printf '\nFine-grained PAT (repo-scoped, Administration: read & write): '
IFS= read -rs GH_RUNNER_TOKEN
printf '\n'
[ -n "$GH_RUNNER_TOKEN" ] || die "token must not be empty"

step "Installing the ARC controller into ${CONTROLLER_NS}"
helm upgrade --install arc \
  --namespace "$CONTROLLER_NS" --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

step "Installing the ${SCALE_SET} scale set into ${RUNNER_NS}"
# minRunners=0: no runner pod exists between jobs. ARC creates a fresh pod per
# job and destroys it after, so no state carries between runs -- which a
# long-lived Deployment runner would not give you.
helm upgrade --install "$SCALE_SET" \
  --namespace "$RUNNER_NS" --create-namespace \
  --set githubConfigUrl="$REPO_URL" \
  --set githubConfigSecret.github_token="$GH_RUNNER_TOKEN" \
  --set minRunners=0 \
  --set maxRunners=1 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

unset GH_RUNNER_TOKEN

step "Waiting for the controller to become ready"
kubectl wait --namespace "$CONTROLLER_NS" \
  --for=condition=Available deployment --all --timeout=180s

step "Controller and listener pods"
kubectl get pods -n "$CONTROLLER_NS"
kubectl get pods -n "$RUNNER_NS"

# The reachability check that actually predicts whether template-push.yml will
# work. If cluster DNS cannot resolve the LAN address, the push job fails the
# same way regardless of the runner being healthy.
step "Checking the cluster can reach Coder"
if kubectl run arc-coder-reach-check --rm -i --restart=Never \
  --namespace "$RUNNER_NS" --image=curlimages/curl --quiet -- \
  curl -fsS --max-time 10 "$CODER_HEALTHZ" >/dev/null 2>&1; then
  printf '    OK   cluster can reach %s\n' "$CODER_HEALTHZ"
else
  printf '    WARN cluster could NOT reach %s\n' "$CODER_HEALTHZ"
  printf '         template-push.yml will fail until this resolves.\n'
fi

step "Registered runners as GitHub sees them"
if command -v gh >/dev/null 2>&1; then
  gh api repos/nickvigilante/homelab-dev-templates/actions/runners \
    --jq '.runners[]? | "\(.name)  \(.status)"' || printf '    (none yet)\n'
else
  printf '    gh not on PATH; check the repo Settings -> Actions -> Runners\n'
fi

cat <<EOF

Done.

With minRunners=0 there is no runner pod until a job arrives; only the
listener runs. To verify end to end, merge anything touching templates/ and
watch template-push.yml -- it should pick up a runner within a few seconds
instead of timing out after 15 minutes.

Reminder: template-push.yml must never gain a pull_request trigger. This
repository is public and this runner is inside the cluster, so that would let
a fork's PR execute arbitrary code on the control plane. PR-time validation
lives in template-validate.yml on a GitHub-hosted runner.
EOF
