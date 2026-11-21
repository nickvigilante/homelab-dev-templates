# Self-hosted runner

`template-push.yml` runs on a self-hosted runner inside the k3s cluster.
It has to: `coder.vigihome.net` resolves only to `192.168.50.135` and `100.71.63.31`, neither routable from a GitHub-hosted runner.

```console
$ getent hosts coder.vigihome.net
192.168.50.135  coder.vigihome.net
100.71.63.31    coder.vigihome.net
```

## Why `template-push.yml` has no `pull_request` trigger

This repository is public.
A workflow triggered by `pull_request` runs code from the pull request's branch, including from forks.

Because this runner lives inside the k3s cluster, a `pull_request` trigger here would let any stranger execute arbitrary code on the cluster control plane, alongside every workspace PVC — and, per the dotfiles kubeconfig gate, potentially alongside a cluster-admin credential.

PR-time checking lives in `.github/workflows/template-validate.yml`, which runs on a GitHub-hosted runner and does a structural check only.
It holds no Tailscale or Coder credential.
A CI node that joins the tailnet would have to be signed by a signing node once Tailnet Lock is on, and a credential that lets GitHub add nodes is the foothold the lock exists to close.

For the provisioner-side check, push a **non-activated** version from a machine already on the tailnet, before merging:

```bash
scripts/vendor-module.sh templates/Base
scripts/push-template.sh Base --activate=false --name "check-$(git rev-parse --short HEAD)" --yes
```

The Coder provisioner runs the Terraform import server-side and rejects anything malformed, without making the version live.

**There is never a reason to add `pull_request` to `template-push.yml`.**
If PR-time checks need to grow, they grow in `template-validate.yml`, and they must not need a tailnet credential.

## Install

`scripts/install-arc-runner.sh` does everything below, prompts for the token
rather than taking it as an argument, and finishes by checking that a pod in
the runner namespace can actually reach Coder — which is what predicts whether
`template-push.yml` will work.

```bash
./scripts/install-arc-runner.sh
```

Use a **fine-grained** PAT scoped to this repository only, with
`Administration: read & write`.
A classic `repo`-scoped token also works but reaches every repository you own,
and this value is stored in a Kubernetes secret, so its blast radius is
whatever the token can reach.

The manual equivalent follows.

The controller:

```bash
helm install arc \
  --namespace arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
```

The scale set. `$GH_RUNNER_TOKEN` is a fine-grained PAT scoped to this repository with `Administration: read & write`:

```bash
helm install arc-runner-set \
  --namespace arc-runners --create-namespace \
  --set githubConfigUrl="https://github.com/nickvigilante/homelab-dev-templates" \
  --set githubConfigSecret.github_token="$GH_RUNNER_TOKEN" \
  --set minRunners=0 \
  --set maxRunners=1 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

`minRunners=0` means no runner pod exists between jobs.
ARC creates a fresh pod per job and destroys it afterwards, so no state carries between runs — which a long-lived Deployment runner would not give you.

The scale set name is also declared in `.github/actionlint.yaml`, because actionlint rejects unknown `runs-on` labels and the lint job would otherwise fail.

## Verify

```bash
kubectl get pods -n arc-systems
gh api repos/nickvigilante/homelab-dev-templates/actions/runners --jq '.runners[].name'
```

The controller pod should be `Running`. With `minRunners=0` only the listener is present; runner pods appear during a job.

Confirm the runner can actually reach Coder, since a failure here fails `template-push.yml` the same way:

```bash
kubectl run coder-reach-check --rm -it --restart=Never \
  --namespace arc-runners --image=curlimages/curl -- \
  curl -fsS --max-time 10 https://coder.vigihome.net/healthz
```

## Secrets

`template-push.yml` reads `CODER_URL` and `CODER_SESSION_TOKEN`.
No workflow reads a Tailscale credential.

The Coder token belongs to a dedicated `ci-template-push` user holding `organization-template-admin`, not to a personal account.
That role carries 23 organization permissions, zero site permissions and zero user permissions.

```bash
coder users create --username ci-template-push --email ci-template-push@vigihome.net
coder organizations members edit-roles ci-template-push organization-template-admin
coder tokens create --user ci-template-push --name github-actions --lifetime 8760h
```

Check it is not over-privileged before storing it — the second command must **fail**:

```bash
CODER_SESSION_TOKEN=<token> coder templates list   # succeeds
CODER_SESSION_TOKEN=<token> coder users list       # must fail
```
