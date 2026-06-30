# Kubeflow + IAM integration via two Istio Ingress gateways (no external Traefik)
#
# Architecture:
#   Traefik (iam)               -> identity bundle ONLY (hydra/kratos/login-ui public routes)
#   ingress-ui (kubeflow)       -> UI / browser login  (ui.kubeflow.com)
#   ingress-m2m (kubeflow)      -> M2M / API access     (api.kubeflow.com)
#   request-auth-config         -> creates a RequestAuthentication on each gateway
#                                  (request-auth-ui -> ingress-ui, request-auth-m2m -> ingress-m2m),
#                                  sharing hydra's JWT issuer via the oauth relation
#
# Access to Kubeflow is done through the two istio ingress gateways, reachable via DNS
# (CoreDNS hosts entries). Traefik is NOT used as an external entrypoint for Kubeflow.
#
# Three models: istio-system, iam, kubeflow
# Requires: juju bootstrapped to microk8s with dns,hostpath-storage,metallb addons

model-istio := "istio-system"
model-iam := "iam"
model-kubeflow := "kubeflow"

# --- channels ---
# IAM charms: latest/stable (latest/edge has kratos identifier_first bug vs login-ui)
ch-postgresql := "14/stable"
ch-hydra := "latest/stable"
ch-kratos := "latest/stable"
ch-login-ui := "latest/stable"
ch-traefik := "latest/stable"
# self-signed-certs: 1/stable for V1 certificate-transfer format (V0 breaks istio/traefik)
ch-self-signed-certs := "1/stable"
# istio + ingress: dev/edge for latest features
ch-istio-k8s := "dev/edge"
ch-istio-ingress := "dev/edge"
# oauth2-proxy
ch-oauth2-proxy := "latest/edge"
# request-authentication-configurator
ch-request-auth := "latest/edge"
# kubeflow charms
ch-kubeflow := "latest/edge"

# name of the istio ingress charm serving the UI / browser login
# the service account created by the charm is <ingress-app>-istio
ingress-app := "ingress-ui"
# name of the second istio ingress charm serving M2M / API access
ingress-api-app := "ingress-m2m"
# request-authentication-configurator: creates a RequestAuthentication per gateway
request-auth-app := "request-authentication-configurator"

# DNS hostnames advertised by the two kubeflow ingress gateways
domain-ui := "ui.kubeflow.com"
domain-api := "api.kubeflow.com"
# DNS hostname advertised by the iam traefik (identity bundle public routes)
domain-auth := "auth.kubeflow.com"

# --- idempotent helpers ---

[private]
_add-model name:
    juju add-model {{name}} 2>/dev/null || true

[private]
_deploy model charm app channel +args="":
    juju deploy -m {{model}} {{charm}} {{app}} --channel {{channel}} --trust {{args}} 2>/dev/null || true

[private]
_integrate model a b:
    juju integrate -m {{model}} {{a}} {{b}} 2>/dev/null || true

[private]
_offer source name:
    juju offer {{source}} {{name}} 2>/dev/null || true

[private]
_consume source model:
    juju consume {{source}} --model {{model}} 2>/dev/null || true

[private]
_wait-for model app:
    @echo "waiting for {{app}} in {{model}}..."
    @juju wait-for application {{app}} -m {{model}} --query='status == "active"' --timeout 20m 2>/dev/null

# ============================================================
# Full setup
# ============================================================

setup: deploy-istio deploy-iam wait-iam deploy-kubeflow create-offers consume-offers integrate-cross-model wait-kubeflow configure-dns
    @echo "=== Setup complete ==="
    @echo "Run 'just -f setup-dual-ingress.just show-ingress-urls' to see URLs"

# ============================================================
# Teardown
# ============================================================

teardown:
    juju destroy-model {{model-kubeflow}} --no-prompt --destroy-storage --force 2>/dev/null || true
    juju destroy-model {{model-iam}} --no-prompt --destroy-storage --force 2>/dev/null || true
    juju destroy-model {{model-istio}} --no-prompt --destroy-storage --force 2>/dev/null || true

# ============================================================
# Status
# ============================================================

status:
    @echo "--- {{model-istio}} ---"
    juju status -m {{model-istio}} --format short 2>/dev/null || echo "(model not found)"
    @echo "--- {{model-iam}} ---"
    juju status -m {{model-iam}} --format short 2>/dev/null || echo "(model not found)"
    @echo "--- {{model-kubeflow}} ---"
    juju status -m {{model-kubeflow}} --format short 2>/dev/null || echo "(model not found)"

# ============================================================
# istio-system model
# ============================================================

deploy-istio:
    just -f {{justfile()}} _add-model {{model-istio}}
    just -f {{justfile()}} _deploy {{model-istio}} istio-k8s istio-k8s {{ch-istio-k8s}}

# ============================================================
# IAM model
# ============================================================

deploy-iam: deploy-iam-charms configure-iam integrate-iam integrate-iam-tls

deploy-iam-charms:
    just -f {{justfile()}} _add-model {{model-iam}}
    just -f {{justfile()}} _deploy {{model-iam}} postgresql-k8s postgresql-k8s {{ch-postgresql}} \
        --config plugin_pg_trgm_enable=True \
        --config plugin_btree_gin_enable=True
    just -f {{justfile()}} _deploy {{model-iam}} hydra hydra {{ch-hydra}}
    just -f {{justfile()}} _deploy {{model-iam}} kratos kratos {{ch-kratos}}
    just -f {{justfile()}} _deploy {{model-iam}} identity-platform-login-ui-operator identity-platform-login-ui-operator {{ch-login-ui}}
    # traefik here serves the identity bundle ONLY (hydra/kratos/login-ui public routes)
    just -f {{justfile()}} _deploy {{model-iam}} traefik-k8s traefik-k8s {{ch-traefik}}
    just -f {{justfile()}} _deploy {{model-iam}} self-signed-certificates self-signed-certificates {{ch-self-signed-certs}}

configure-iam:
    # kratos needs dev mode for HTTP internally
    juju config -m {{model-iam}} kratos dev=true
    # disable MFA so users can log in with just a password
    juju config -m {{model-iam}} kratos enforce_mfa=false
    # DNS hostname advertised by traefik for the identity bundle public routes
    juju config -m {{model-iam}} traefik-k8s external_hostname={{domain-auth}}

integrate-iam:
    # database
    just -f {{justfile()}} _integrate {{model-iam}} hydra:pg-database postgresql-k8s:database
    just -f {{justfile()}} _integrate {{model-iam}} kratos:pg-database postgresql-k8s:database
    # hydra <-> kratos <-> login-ui
    just -f {{justfile()}} _integrate {{model-iam}} kratos:hydra-endpoint-info hydra:hydra-endpoint-info
    just -f {{justfile()}} _integrate {{model-iam}} identity-platform-login-ui-operator:hydra-endpoint-info hydra:hydra-endpoint-info
    just -f {{justfile()}} _integrate {{model-iam}} identity-platform-login-ui-operator:ui-endpoint-info hydra:ui-endpoint-info
    just -f {{justfile()}} _integrate {{model-iam}} identity-platform-login-ui-operator:ui-endpoint-info kratos:ui-endpoint-info
    just -f {{justfile()}} _integrate {{model-iam}} identity-platform-login-ui-operator:kratos-info kratos:kratos-info
    # public routes via traefik (identity bundle)
    just -f {{justfile()}} _integrate {{model-iam}} hydra:public-route traefik-k8s
    just -f {{justfile()}} _integrate {{model-iam}} kratos:public-route traefik-k8s
    just -f {{justfile()}} _integrate {{model-iam}} identity-platform-login-ui-operator:public-route traefik-k8s

integrate-iam-tls:
    # TLS on traefik - login-ui hardcodes https in normalise_url
    just -f {{justfile()}} _integrate {{model-iam}} self-signed-certificates:certificates traefik-k8s:certificates
    # CA cert so kratos and login-ui trust traefik's TLS
    just -f {{justfile()}} _integrate {{model-iam}} self-signed-certificates:send-ca-cert kratos:receive-ca-cert
    just -f {{justfile()}} _integrate {{model-iam}} self-signed-certificates:send-ca-cert identity-platform-login-ui-operator:receive-ca-cert

wait-iam:
    just -f {{justfile()}} _wait-for {{model-iam}} hydra
    just -f {{justfile()}} _wait-for {{model-iam}} self-signed-certs

wait-kubeflow:
    just -f {{justfile()}} _wait-for {{model-kubeflow}} {{ingress-app}}
    just -f {{justfile()}} _wait-for {{model-kubeflow}} {{ingress-api-app}}
    just -f {{justfile()}} _wait-for {{model-kubeflow}} {{request-auth-app}}
    just -f {{justfile()}} _wait-for {{model-kubeflow}} oauth2-proxy-k8s
    just -f {{justfile()}} _wait-for {{model-kubeflow}} kubeflow-dashboard
    just -f {{justfile()}} _wait-for {{model-kubeflow}} kubeflow-profiles
    just -f {{justfile()}} _wait-for {{model-kubeflow}} kserve-controller
    just -f {{justfile()}} _wait-for {{model-kubeflow}} jupyter-controller
    just -f {{justfile()}} _wait-for {{model-kubeflow}} jupyter-ui
    just -f {{justfile()}} _wait-for {{model-kubeflow}} github-profiles-automator

# ============================================================
# Kubeflow model
# ============================================================

deploy-kubeflow: deploy-kubeflow-charms configure-kubeflow integrate-kubeflow

deploy-kubeflow-charms:
    just -f {{justfile()}} _add-model {{model-kubeflow}}
    # istio ingress gateway for the UI / browser login
    just -f {{justfile()}} _deploy {{model-kubeflow}} istio-ingress-k8s {{ingress-app}} {{ch-istio-ingress}}
    # second istio ingress gateway for M2M / API access
    just -f {{justfile()}} _deploy {{model-kubeflow}} istio-ingress-k8s {{ingress-api-app}} {{ch-istio-ingress}}
    # request-authentication-configurator: creates a RequestAuthentication per gateway
    just -f {{justfile()}} _deploy {{model-kubeflow}} request-authentication-configurator {{request-auth-app}} {{ch-request-auth}} \
        --config user-id-header-name=kubeflow-userid
    # oauth2-proxy for browser auth (forward-auth)
    just -f {{justfile()}} _deploy {{model-kubeflow}} oauth2-proxy-k8s oauth2-proxy-k8s {{ch-oauth2-proxy}}
    # kubeflow charms
    just -f {{justfile()}} _deploy {{model-kubeflow}} kubeflow-dashboard kubeflow-dashboard latest/edge/pr-325
    just -f {{justfile()}} _deploy {{model-kubeflow}} kubeflow-profiles kubeflow-profiles {{ch-kubeflow}} \
        --config istio-gateway-service-account={{ingress-app}}-istio \
        --config service-mesh-mode=istio-ambient
    just -f {{justfile()}} _deploy {{model-kubeflow}} kserve-controller kserve-controller {{ch-kubeflow}} \
        --config deployment-mode=Standard

    just -f {{justfile()}} _deploy {{model-kubeflow}} jupyter-controller jupyter-controller {{ch-kubeflow}}
    just -f {{justfile()}} _deploy {{model-kubeflow}} jupyter-ui jupyter-ui {{ch-kubeflow}}
    # github-profiles-automator: syncs kubeflow Profiles from a GitHub PMR repo
    just -f {{justfile()}} _deploy {{model-kubeflow}} github-profiles-automator github-profiles-automator latest/edge
    # kubeflow RBAC roles
    just -f {{justfile()}} _deploy {{model-kubeflow}} kubeflow-roles kubeflow-roles {{ch-kubeflow}}
    # admission webhook for pod defaulting / mutation
    just -f {{justfile()}} _deploy {{model-kubeflow}} admission-webhook admission-webhook {{ch-kubeflow}}
    # istio beacon for service mesh enrolment
    just -f {{justfile()}} _deploy {{model-kubeflow}} istio-beacon-k8s istio-beacon-k8s {{ch-istio-ingress}}
    # self-signed-certs for ingress TLS + CA sharing with traefik
    just -f {{justfile()}} _deploy {{model-kubeflow}} self-signed-certificates self-signed-certificates {{ch-self-signed-certs}}

configure-kubeflow:
    # oauth2-proxy: dev=true sets SSL_INSECURE_SKIP_VERIFY (receive-ca-cert data is ignored by the charm)
    juju config -m {{model-kubeflow}} oauth2-proxy-k8s dev=true enable_jwt_bearer_tokens=true set_authorization_header=true
    # DNS hostnames advertised by the two ingress gateways
    juju config -m {{model-kubeflow}} {{ingress-app}} external_hostname={{domain-ui}}
    juju config -m {{model-kubeflow}} {{ingress-api-app}} external_hostname={{domain-api}}
    # kserve-controller: InferenceService subdomains are built under the M2M gateway domain
    juju config -m {{model-kubeflow}} kserve-controller domain-name={{domain-api}}
    # github-profiles-automator: ingress gateway principals (UI = primary, M2M = additional) + PMR repo
    juju config -m {{model-kubeflow}} github-profiles-automator \
        istio-ingressgateway-principal=cluster.local/ns/{{model-kubeflow}}/sa/{{ingress-app}}-istio \
        additional-principals=cluster.local/ns/{{model-kubeflow}}/sa/{{ingress-api-app}}-istio \
        repository=https://github.com/NohaIhab/pmr-github-profiles-automator.git

integrate-kubeflow:
    # --- UI ingress (browser login) ---
    # ingress: forward-auth (browser login) + oauth2-proxy's own ingress
    just -f {{justfile()}} _integrate {{model-kubeflow}} oauth2-proxy-k8s:forward-auth {{ingress-app}}:forward-auth
    just -f {{justfile()}} _integrate {{model-kubeflow}} oauth2-proxy-k8s:ingress {{ingress-app}}:ingress-unauthenticated
    # kubeflow-dashboard exposed via the UI ingress (ingress route)
    just -f {{justfile()}} _integrate {{model-kubeflow}} kubeflow-dashboard:istio-ingress-route {{ingress-app}}:istio-ingress-route
    # TLS on the UI ingress
    just -f {{justfile()}} _integrate {{model-kubeflow}} self-signed-certificates:certificates {{ingress-app}}:certificates

    # --- M2M ingress (API access) ---
    # kubeflow-dashboard exposed via the M2M ingress (ingress route)
    just -f {{justfile()}} _integrate {{model-kubeflow}} kubeflow-dashboard:istio-ingress-route {{ingress-api-app}}:istio-ingress-route
    # TLS on the M2M ingress
    just -f {{justfile()}} _integrate {{model-kubeflow}} self-signed-certificates:certificates {{ingress-api-app}}:certificates

    # --- request-authentication-configurator: one RequestAuthentication per gateway ---
    just -f {{justfile()}} _integrate {{model-kubeflow}} {{request-auth-app}}:request-auth-ui {{ingress-app}}:istio-request-auth
    just -f {{justfile()}} _integrate {{model-kubeflow}} {{request-auth-app}}:request-auth-m2m {{ingress-api-app}}:istio-request-auth

    # --- kubeflow-dashboard <-> kubeflow-profiles ---
    just -f {{justfile()}} _integrate {{model-kubeflow}} kubeflow-dashboard:kubeflow-profiles kubeflow-profiles:profiles
    just -f {{justfile()}} _integrate {{model-kubeflow}} kubeflow-dashboard:kubeflow-profiles kubeflow-profiles
    # enrol kubeflow charms into the service mesh via istio-beacon
    just -f {{justfile()}} _integrate {{model-kubeflow}} kubeflow-dashboard:service-mesh istio-beacon-k8s:service-mesh
    just -f {{justfile()}} _integrate {{model-kubeflow}} kserve-controller:service-mesh istio-beacon-k8s:service-mesh
    just -f {{justfile()}} _integrate {{model-kubeflow}} kubeflow-profiles:service-mesh istio-beacon-k8s:service-mesh
    just -f {{justfile()}} _integrate {{model-kubeflow}} kubeflow-roles:service-mesh istio-beacon-k8s:service-mesh
    just -f {{justfile()}} _integrate {{model-kubeflow}} admission-webhook:service-mesh istio-beacon-k8s:service-mesh
    just -f {{justfile()}} _integrate {{model-kubeflow}} github-profiles-automator:service-mesh istio-beacon-k8s:service-mesh
    # kserve-controller gateway metadata from the M2M istio ingress
    just -f {{justfile()}} _integrate {{model-kubeflow}} kserve-controller:gateway-metadata {{ingress-api-app}}:gateway-metadata
    # jupyter: service mesh enrolment, gateway metadata, ingress route, dashboard links
    just -f {{justfile()}} _integrate {{model-kubeflow}} jupyter-controller:service-mesh istio-beacon-k8s:service-mesh
    just -f {{justfile()}} _integrate {{model-kubeflow}} jupyter-ui:service-mesh istio-beacon-k8s:service-mesh
    just -f {{justfile()}} _integrate {{model-kubeflow}} jupyter-controller:gateway-metadata {{ingress-app}}:gateway-metadata
    just -f {{justfile()}} _integrate {{model-kubeflow}} jupyter-ui:istio-ingress-route {{ingress-app}}:istio-ingress-route
    just -f {{justfile()}} _integrate {{model-kubeflow}} jupyter-ui:dashboard-links kubeflow-dashboard:links

# ============================================================
# Cross-model offers, consumes, and integrations
# ============================================================

create-offers:
    # istio-system -> kubeflow: istio mesh config for the gateways
    just -f {{justfile()}} _offer {{model-istio}}.istio-k8s:istio-ingress-config istio-ingress-config
    # iam -> kubeflow: hydra OAuth for oauth2-proxy
    just -f {{justfile()}} _offer {{model-iam}}.hydra:oauth hydra-oauth
    # iam -> kubeflow: CA cert so oauth2-proxy trusts traefik's TLS
    just -f {{justfile()}} _offer {{model-iam}}.self-signed-certificates:send-ca-cert iam-ca-cert
    # kubeflow -> iam: CA cert so traefik trusts istio gateway TLS
    just -f {{justfile()}} _offer {{model-kubeflow}}.self-signed-certificates:send-ca-cert kubeflow-ca

consume-offers:
    just -f {{justfile()}} _consume admin/{{model-istio}}.istio-ingress-config {{model-kubeflow}}
    just -f {{justfile()}} _consume admin/{{model-iam}}.hydra-oauth {{model-kubeflow}}
    just -f {{justfile()}} _consume admin/{{model-iam}}.iam-ca-cert {{model-kubeflow}}
    # istio-system consumes iam CA for JWKS trust
    just -f {{justfile()}} _consume admin/{{model-iam}}.iam-ca-cert {{model-istio}}
    # iam consumes kubeflow CA so traefik trusts istio gateway certs
    just -f {{justfile()}} _consume admin/{{model-kubeflow}}.kubeflow-ca {{model-iam}}

integrate-cross-model:
    # both gateways get istio mesh config
    just -f {{justfile()}} _integrate {{model-kubeflow}} {{ingress-app}}:istio-ingress-config istio-ingress-config
    just -f {{justfile()}} _integrate {{model-kubeflow}} {{ingress-api-app}}:istio-ingress-config istio-ingress-config
    # oauth2-proxy -> hydra OAuth
    just -f {{justfile()}} _integrate {{model-kubeflow}} oauth2-proxy-k8s:oauth hydra-oauth
    # request-auth-config -> hydra OAuth (to obtain the JWT issuer for both RequestAuthentications)
    just -f {{justfile()}} _integrate {{model-kubeflow}} {{request-auth-app}}:oauth hydra-oauth
    # oauth2-proxy trusts traefik's TLS
    just -f {{justfile()}} _integrate {{model-kubeflow}} oauth2-proxy-k8s:receive-ca-cert iam-ca-cert
    # istiod trusts iam CA for JWKS endpoint
    just -f {{justfile()}} _integrate {{model-istio}} istio-k8s:jwks-ca-cert iam-ca-cert
    # traefik trusts kubeflow CA for istio gateway TLS (endToEndTLS)
    just -f {{justfile()}} _integrate {{model-iam}} traefik-k8s:receive-ca-cert kubeflow-ca

# ============================================================
# JWT configuration
# ============================================================

# The JWT issuer for both gateways is now sourced from hydra by the
# request-authentication-configurator via its `oauth` relation (see
# integrate-cross-model), so no manual jwt-issuer config is required here.
# This recipe remains for manual override of kubeflow-dashboard's issuer if needed.
configure-jwt:
    #!/usr/bin/env bash
    set -euo pipefail
    ISSUER_HOST=$(kubectl -n {{model-iam}} get svc traefik-k8s-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null \
        || kubectl -n {{model-iam}} get svc -l app.kubernetes.io/name=traefik-k8s -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
    echo "Configuring JWT issuer to https://$ISSUER_HOST"
    juju config -m {{model-kubeflow}} kubeflow-dashboard \
        jwt-issuer="https://$ISSUER_HOST"

# ============================================================
# Domain + DNS configuration (two ingress gateways)
# ============================================================

# Point the UI and API hostnames at their respective istio gateway LB IPs in CoreDNS.
# external_hostname is set on the charms in configure-kubeflow.
configure-gateways-dns:
    #!/usr/bin/env bash
    set -euo pipefail
    UI_IP=$(kubectl -n {{model-kubeflow}} get svc {{ingress-app}}-istio \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    API_IP=$(kubectl -n {{model-kubeflow}} get svc {{ingress-api-app}}-istio \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    echo "UI  gateway {{domain-ui}}  -> $UI_IP"
    echo "API gateway {{domain-api}} -> $API_IP"
    # detect the CoreDNS configmap (microk8s: "coredns", Canonical K8s: "ck-dns-coredns")
    CM=$(kubectl -n kube-system get configmap coredns -o name 2>/dev/null \
        || kubectl -n kube-system get configmap ck-dns-coredns -o name 2>/dev/null \
        || kubectl -n kube-system get configmap -o name \
            | grep -E 'coredns' | head -n1)
    if [[ -z "$CM" ]]; then echo "could not find a CoreDNS configmap in kube-system" >&2; exit 1; fi
    CM_NAME=${CM##*/}
    echo "Using CoreDNS configmap: $CM_NAME"
    # detect the matching CoreDNS deployment for the rollout restart
    DEPLOY=$(kubectl -n kube-system get deploy coredns -o name 2>/dev/null \
        || kubectl -n kube-system get deploy ck-dns-coredns -o name 2>/dev/null \
        || kubectl -n kube-system get deploy -o name \
            | grep -E 'coredns' | head -n1)
    CURRENT=$(kubectl -n kube-system get configmap "$CM_NAME" -o jsonpath='{.data.Corefile}')
    PATCHED=$(CURRENT="$CURRENT" UI_IP="$UI_IP" API_IP="$API_IP" \
        DOMAIN_UI="{{domain-ui}}" DOMAIN_API="{{domain-api}}" python3 <<'PY'
    import os, re
    corefile = os.environ["CURRENT"]
    ui_ip, api_ip = os.environ["UI_IP"], os.environ["API_IP"]
    domain_ui, domain_api = os.environ["DOMAIN_UI"], os.environ["DOMAIN_API"]
    block = (
        "    hosts {\n"
        + "        " + ui_ip + " " + domain_ui + "\n"
        + "        " + api_ip + " " + domain_api + "\n"
        + "        fallthrough\n"
        + "    }\n"
    )
    # drop any previous hosts block that references either of our domains
    pattern = re.compile(
        r"[ \t]*hosts \{[^}]*(?:%s|%s)[^}]*\}\n"
        % (re.escape(domain_ui), re.escape(domain_api))
    )
    corefile = pattern.sub("", corefile)
    # insert the fresh block before the kubernetes plugin line
    corefile = re.sub(r"(\n)([ \t]*kubernetes cluster\.local)",
                      "\n" + block + r"\2", corefile, count=1)
    print(corefile, end="")
    PY
    )
    kubectl -n kube-system create configmap "$CM_NAME" --from-literal=Corefile="$PATCHED" --dry-run=client -o yaml \
        | kubectl apply -f -
    if [[ -n "${DEPLOY:-}" ]]; then
        kubectl -n kube-system rollout restart "$DEPLOY"
    fi
    echo "Done. {{domain-ui}} -> $UI_IP, {{domain-api}} -> $API_IP in $CM_NAME"

# Add the two gateway hostnames to the local /etc/hosts so the host/browser can
# resolve them (CoreDNS only handles in-cluster resolution). Requires sudo.
update-local-hosts:
    #!/usr/bin/env bash
    set -euo pipefail
    UI_IP=$(kubectl -n {{model-kubeflow}} get svc {{ingress-app}}-istio \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    API_IP=$(kubectl -n {{model-kubeflow}} get svc {{ingress-api-app}}-istio \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    AUTH_IP=$(kubectl -n {{model-iam}} get svc traefik-k8s-lb \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [[ -z "$UI_IP" || -z "$API_IP" || -z "$AUTH_IP" ]]; then
        echo "could not resolve gateway LB IPs (are the gateways active?)" >&2; exit 1
    fi
    echo "UI   gateway {{domain-ui}}   -> $UI_IP"
    echo "API  gateway {{domain-api}}  -> $API_IP"
    echo "AUTH gateway {{domain-auth}} -> $AUTH_IP"
    # remove any previous entries for these hostnames, then append the fresh ones
    sudo sed -i "/[[:space:]]{{domain-ui}}$/d;/[[:space:]]{{domain-api}}$/d;/[[:space:]]{{domain-auth}}$/d" /etc/hosts
    echo "$UI_IP {{domain-ui}}"     | sudo tee -a /etc/hosts >/dev/null
    echo "$API_IP {{domain-api}}"   | sudo tee -a /etc/hosts >/dev/null
    echo "$AUTH_IP {{domain-auth}}" | sudo tee -a /etc/hosts >/dev/null
    echo "Updated /etc/hosts:"
    grep -E "{{domain-ui}}|{{domain-api}}|{{domain-auth}}" /etc/hosts

# Configure both in-cluster (CoreDNS) and host (/etc/hosts) DNS for the gateways.
configure-dns: configure-gateways-dns update-local-hosts

# ============================================================
# Show ingress URLs
# ============================================================

show-ingress-urls:
    #!/usr/bin/env bash
    set -euo pipefail
    UI_IP=$(kubectl -n {{model-kubeflow}} get svc {{ingress-app}}-istio \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    API_IP=$(kubectl -n {{model-kubeflow}} get svc {{ingress-api-app}}-istio \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    echo "UI  gateway LB IP: $UI_IP"
    echo "API gateway LB IP: $API_IP"
    echo "KubeFlow Dashboard (UI):  https://{{domain-ui}}/"
    echo "KubeFlow Dashboard (M2M): https://{{domain-api}}/"

# ============================================================
# User management
# ============================================================

# create an admin account in kratos and a matching kubeflow Profile
# usage: just -f setup-dual-ingress.just create-admin admin admin@email.com
create-admin name email:
    just -f {{justfile()}} create-kratos-admin {{name}} {{email}}
    just -f {{justfile()}} create-kubeflow-profile {{name}} {{email}}

# create the kratos admin account
create-kratos-admin name email:
    juju run -m {{model-iam}} kratos/0 create-admin-account username={{name}} email={{email}}

# create a kubeflow Profile for a user
# usage: just -f setup-dual-ingress.just create-kubeflow-profile admin admin@email.com
create-kubeflow-profile name email:
    #!/usr/bin/env bash
    set -euo pipefail
    cat <<EOF | kubectl apply -f -
    apiVersion: kubeflow.org/v1
    kind: Profile
    metadata:
      name: {{name}}
    spec:
      owner:
        kind: User
        name: {{email}}
    EOF
    echo "Profile '{{name}}' created for {{email}}"

# create a test user in kratos
create-user email password:
    #!/usr/bin/env bash
    set -euo pipefail
    IDENTITY_ID=$(kubectl -n {{model-iam}} exec kratos-0 -c kratos -- \
        kratos import identities --endpoint http://localhost:4434 /dev/stdin <<EOIDENT | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])"
    [{
      "schema_id": "default",
      "traits": {"email": "{{email}}"},
      "credentials": {
        "password": {
          "config": {"password": "{{password}}"}
        }
      }
    }]
    EOIDENT
    )
    echo "Created identity: $IDENTITY_ID"
