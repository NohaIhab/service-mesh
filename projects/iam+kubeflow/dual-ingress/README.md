# Kubeflow + IAM with dual Istio Ingress gateways

A dev setup that deploys Kubeflow integrated with the Canonical Identity Platform
(IAM) using **two** Istio ingress gateways on Istio ambient mesh:

- `ingress-ui` (`ui.kubeflow.com`) — UI / browser login, fronted by oauth2-proxy
  (forward-auth).
- `ingress-m2m` (`api.kubeflow.com`) — machine-to-machine / API access, validated
  by a `RequestAuthentication` per gateway sharing hydra's JWT issuer.

Traefik (in the `iam` model) fronts the identity bundle only (hydra / kratos /
login-ui public routes); it is **not** the external entrypoint for Kubeflow.

## Prerequisites

- Juju bootstrapped to a Kubernetes cloud with a LoadBalancer provider.
  - On microk8s: enable the `dns`, `hostpath-storage`, and `metallb` addons.
  - On Canonical Kubernetes: ensure MetalLB (or another LB) is providing
    addresses.
- [`just`](https://github.com/casey/just), `kubectl`, `jq`, and `python3` on the
  host running the recipes.
- `sudo` access (the DNS recipe writes gateway hostnames to `/etc/hosts`).

## Models

| Model          | Charms |
| -------------- | ------ |
| `istio-system` | istio-k8s |
| `iam`          | hydra, kratos, identity-platform-login-ui-operator, postgresql-k8s, self-signed-certificates, traefik-k8s |
| `kubeflow`     | ingress-ui, ingress-m2m, istio-beacon-k8s, oauth2-proxy-k8s, request-authentication-configurator, kubeflow-dashboard, kubeflow-profiles, kubeflow-roles, admission-webhook, kserve-controller, jupyter-controller, jupyter-ui, github-profiles-automator, self-signed-certificates |

## Usage

Run everything from this directory.

```bash
# full deployment (all three models, cross-model relations, and DNS)
just -f setup-dual-ingress.just setup

# create an admin account in kratos + a matching kubeflow Profile
just -f setup-dual-ingress.just create-admin "username" "user@email.com"

# show the ingress URLs
just -f setup-dual-ingress.just show-ingress-urls
```

### Useful targets

| Target | Description |
| ------ | ----------- |
| `setup` | End-to-end deploy + configure + integrate + DNS. |
| `status` | `juju status` across all three models. |
| `configure-dns` | Point both gateway hostnames at their LB IPs in CoreDNS and `/etc/hosts`. |
| `show-ingress-urls` | Print the gateway LB IPs and dashboard URLs. |
| `create-admin <name> <email>` | Create a kratos admin + kubeflow Profile. |
| `teardown` | Destroy all three models. |

List all available targets with:

```bash
just -f setup-dual-ingress.just --list
```

## Notes

- DNS resolution is host-local: `configure-dns` adds `ui.kubeflow.com` and
  `api.kubeflow.com` to CoreDNS (in-cluster) and `/etc/hosts` (host/browser).
- KServe (`kserve-controller`, Standard mode) publishes per-service **subdomain**
  routes under `api.kubeflow.com` (e.g. `my-model-predictor-admin.api.kubeflow.com`).
  The `istio-ingress-k8s` charm currently pins each listener to the exact
  `external_hostname`, so those subdomain routes do not attach until the gateway
  listener is widened to a wildcard (`*.api.kubeflow.com`). See
  [canonical/service-mesh#102](https://github.com/canonical/service-mesh/issues/102).
