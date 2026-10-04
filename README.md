# Scenario 3 – Scenarios 1 and 2 on AKS

Every component of Scenario 1 (Orders voice analyst) and Scenario 2 (PTO lookup) is built
as its own Docker image, pushed to Azure Container Registry, and deployed to one AKS
cluster with Helm. A GitHub Actions pipeline runs build → test → push → deploy on every
change to `Scenario1/`, `Scenario2/` or `Scenario3/`.

```
                    DNS: ai.contoso.com, *.ai.contoso.com ─▶ ingress public IP
                                         │ HTTPS (TLS cert from Key Vault)
┌──────────────────────────── AKS  namespace ai-platform ─────────────────────────────┐
│  Ingress (app routing NGINX)                                                         │
│   ai.contoso.com/             ─▶ web            (Scenario1/web; /hr/ = Scenario2/web)│
│   ai.contoso.com/api          ─▶ orders-api     ─▶ Foundry agent ─┐                  │
│   ai.contoso.com/pto, /hr,    ─▶ oauth2-proxy (Entra ID sign-in,  │ MCP over HTTPS   │
│                 /oauth2           PTO.Read role) ─▶ pto-api       │ + x-api-key      │
│   mcp-databricks.ai.contoso.com/mcp ─▶ mcp-databricks  ◀──────────┤                  │
│   mcp-mysql.ai.contoso.com/mcp      ─▶ mcp-mysql       ◀──────────┤                  │
│   mcp-snowflake.ai.contoso.com/mcp  ─▶ mcp-snowflake   ◀──────────┘                  │
│                                                                                      │
│  CronJobs: mysql-loader (hourly :30) · employee-sync (hourly :15) · handbook-ingest  │
│  Secrets: Key Vault ─▶ Secrets Store CSI driver ─▶ Kubernetes Secrets (+ TLS cert)   │
│  Identity: workload identity ─▶ ordersva-id / ptorag-id / ptorag-pipelines-id        │
└──────────────────────────────────────────────┬──────────────────────────────────────┘
                     static egress IP (allowed by PostgreSQL + Databricks-on-AWS)
```

## Images

All images build from the **repository root** (the folder that contains `Scenario1/2/3`),
so they can combine code from more than one scenario. Each Dockerfile has a
`Dockerfile.dockerignore` that admits only the files it needs.

| Image | Dockerfile | Source | Runs as |
|---|---|---|---|
| `web` | `docker/web` | `Scenario1/web` at `/`, `Scenario2/web` at `/hr/` (nginx-unprivileged) | Deployment |
| `orders-api` | `docker/orders-api` | `Scenario1/api` | Deployment |
| `pto-api` | `docker/pto-api` | `Scenario2/api` + `Scenario2/common` | Deployment |
| `mcp-databricks`, `mcp-mysql`, `mcp-snowflake` | `docker/mcp` (`MCP_BACKEND` build arg) | `Scenario1/mcp_servers`, each with only its own DB connector | Deployment ×3 |
| `mysql-loader` | `docker/mysql-loader` | `Scenario1/pipelines/mysql` | CronJob |
| `employee-sync` | `docker/pto-pipeline` (`PIPELINE=sync_employees.py`) | `Scenario2/pipelines/postgres` | CronJob |
| `handbook-ingest` | `docker/pto-pipeline` (`PIPELINE=ingest_handbook.py`) | `Scenario2/pipelines/postgres` | CronJob |
| oauth2-proxy | upstream `quay.io/oauth2-proxy/oauth2-proxy` | – | Deployment |

All images run as non-root with numeric UIDs. In the cluster they also run with a
read-only root filesystem, all capabilities dropped and the `RuntimeDefault` seccomp
profile, which meets the Pod Security `restricted` level.

`docker/constraints.txt` caps two dependencies whose new major versions break the scenario
code: `mcp` 2.x renamed `FastMCP`, and `azure-ai-projects` 2.x removed the threads/runs
Agents API that `Scenario1/api/app/agent.py` uses. Every image build and every CI test step
installs with these caps.

Build one image locally (from the repo root):

```bash
docker build -f Scenario3/docker/mcp/Dockerfile --build-arg MCP_BACKEND=mysql -t mcp-mysql .
```

The Databricks and Snowflake pipelines from Scenario 1 run inside those platforms (a
Lakeflow Job and a Snowflake TASK), so they have no container.

## Layout

| Path | What it is |
|---|---|
| `docker/` | One Dockerfile (+ `.dockerignore`) per image, the nginx config, pip constraints |
| `deploy/helm/ai-platform/` | Helm chart: Deployments, Services, HPAs, PDBs, CronJobs, Ingress, SecretProviderClasses, ServiceAccounts, NetworkPolicies |
| `deploy/helm/values-prod.yaml` | Environment settings (no secrets) – fill in the placeholders |
| `infra/aks.bicep` | AKS cluster, egress IP, federated credentials, AcrPull, PostgreSQL firewall rule, CI/CD roles |
| `infra/tls-cert-policy.json` | Key Vault certificate policy for the ingress certificate |
| `.github/workflows/ai-platform.yml` | CI/CD pipeline |

## How each requirement is met

| Requirement | Implementation |
|---|---|
| Deployments and Services | `templates/apps.yaml`: 2+ replicas spread across zones, rolling updates with `maxUnavailable: 0`, startup/readiness/liveness probes, CPU-based HPA, and a PodDisruptionBudget for each Deployment. |
| Pipeline jobs as CronJobs | `templates/cronjobs.yaml`: `concurrencyPolicy: Forbid`, deadlines, retries, and TTL cleanup of finished Jobs. |
| Ingress | One `networking.k8s.io/v1` Ingress serves the website and both APIs on one host, plus one host per MCP server, because Foundry calls each MCP server at `/mcp`. |
| TLS on the Ingress | A Key Vault certificate is synced by the Secrets Store CSI driver into the `kubernetes.io/tls` Secret `ingress-tls`. It rotates automatically: Key Vault auto-renews, and the driver re-syncs every 2 minutes. HTTP is redirected to HTTPS. |
| Secrets from Key Vault | One SecretProviderClass per workload. Each pod receives only its own secrets, and reads them with its own managed identity through workload identity. No secret appears in Git, Helm values or the pipeline. |
| Least privilege / isolation | Default-deny NetworkPolicy. Only the ingress controller can reach the exposed apps, and only oauth2-proxy can reach `pto-api`, so the identity headers it injects can't be forged. CronJob pods accept no traffic. The PTO API and pipelines keep separate Postgres roles (`ptorag-id` read-only, `ptorag-pipelines-id` writer). |
| PTO sign-in | oauth2-proxy (Entra ID, `PTO.Read` app role) runs in front of `/pto` and `/hr`. `pto-api` runs with `PTO_AUTH_MODE=proxy` and checks the role again. |
| CI/CD | GitHub Actions: tests (Scenario 1 SQL guard, Scenario 2 API + pipelines, an SDK import check, Helm lint, kubeconform, Bicep build) → build 9 images (pushed only from `main`, tagged with the git SHA, with SBOM and provenance) → `helm upgrade --atomic` to AKS (rolls back if pods don't become ready) → smoke test. |

**About the ingress controller.** The chart targets the AKS application routing add-on
(managed NGINX). Azure supports that add-on only through **November 2026**. The Ingress
uses only the standard API, with no NGINX auth or rewrite annotations: sign-in is handled
by oauth2-proxy and TLS by the CSI driver. To move to Application Gateway for Containers,
which supports the Ingress API, change `ingress.className` and
`networkPolicy.ingressControllerPeers` in the values.

## One-time setup

Prerequisites: Azure CLI 2.86+, Helm 3, kubectl, kubelogin. Scenario 1 and Scenario 2
infrastructure must already be deployed. Use `deployApps=false` in both, so their Container
Apps don't run alongside AKS. Scenario 1 creates the ACR that all images go to.

**1. Ingress TLS certificate (Scenario 1 Key Vault).** Edit the host names in
`infra/tls-cert-policy.json`. For production, set `issuerParameters.name` to a Key Vault
CA issuer (DigiCert or GlobalSign), or import a certificate. Foundry only connects to MCP
servers whose certificate is publicly trusted, so a self-signed certificate is for testing
only.

```bash
az keyvault certificate create --vault-name <ordersva-kv> -n ai-platform-tls -p @Scenario3/infra/tls-cert-policy.json
```

**2. Secrets for oauth2-proxy (Scenario 2 Key Vault).** `entra-auth-client-secret` already
exists if Scenario 2 was deployed with `entraAuthClientId`. Add the cookie secret:

```bash
az keyvault secret set --vault-name <ptorag-kv> -n oauth2-proxy-cookie-secret --value "$(openssl rand -base64 32 | tr -- '+/' '-_')"
```

In the Scenario 2 app registration, add the redirect URI `https://<host>/oauth2/callback`
(platform: Web). Assign the `PTO.Read` app role to the users who may look up PTO.

**3. CI/CD identity.** Create an app registration for GitHub Actions, with two federated
credentials: `repo:<owner>/<repo>:ref:refs/heads/main` and `repo:<owner>/<repo>:environment:production`. Note its service principal object ID.

**4. AKS cluster.**

```bash
az group create -n rg-ai-platform-aks -l eastus
```
```bash
az deployment group create -g rg-ai-platform-aks -f Scenario3/infra/aks.bicep -p acrName=<ordersva-acr> ordersResourceGroup=rg-orders-va ptoResourceGroup=<scenario2-rg> ptoPostgresServerName=<ptorag-pg-xxxxxx> deployerPrincipalId=<ci-sp-object-id>
```

The outputs include the three identity client IDs for `values-prod.yaml` and
`egressIpAddress`. Add that IP to the Databricks-on-AWS workspace IP access list, and to
any Snowflake network policy. PostgreSQL is already handled. MySQL allows Azure IPs.

**5. Namespace** (the CI/CD role can't create namespaces):

```bash
az aks get-credentials -g rg-ai-platform-aks -n ai-platform-aks
```
```bash
kubectl create namespace ai-platform
```
```bash
kubectl label namespace ai-platform pod-security.kubernetes.io/enforce=restricted
```

**6. Values.** Fill in every `<...>` in `deploy/helm/values-prod.yaml`.

**7. DNS.** Point `<host>` and `*.<host>` at the ingress controller's public IP:

```bash
kubectl get svc -n app-routing-system nginx -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
```

**8. GitHub.** Copy `Scenario3/.github/workflows/ai-platform.yml` to
`<repo root>/.github/workflows/`, because GitHub only runs workflows from the root. Then
set these repository variables: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`, `ACR_NAME`, `AKS_RESOURCE_GROUP`, `AKS_CLUSTER_NAME`,
`APP_HOST`. Create the `production` environment; add required reviewers if you want a
manual approval gate.

Push to `main` (or run the workflow manually) to build, test, push and deploy.

## Operations

Run a pipeline job now, for example after uploading a new handbook to `landing/handbook/`:

```bash
kubectl create job --from=cronjob/handbook-ingest handbook-ingest-manual -n ai-platform
```

Roll back to the previous release:

```bash
helm rollback ai-platform -n ai-platform
```

Deploy by hand (same command the pipeline runs):

```bash
helm upgrade --install ai-platform Scenario3/deploy/helm/ai-platform -n ai-platform -f Scenario3/deploy/helm/values-prod.yaml --set image.registry=<acr>.azurecr.io --set image.tag=<git-sha> --atomic --wait
```

Rotate a secret: update it in Key Vault. The CSI driver re-syncs within 2 minutes. Pods
read secrets as environment variables at start, so restart the affected Deployment:
`kubectl rollout restart deploy/<name> -n ai-platform`. CronJobs pick it up on their next run.

## Change made outside Scenario 3

`Scenario2/api/app/auth.py` and `config.py` have a new `PTO_AUTH_MODE=proxy`. It trusts
`X-Forwarded-User` and `X-Forwarded-Groups` from oauth2-proxy, which strips any copies the
client sent. The NetworkPolicy makes oauth2-proxy the only thing that can reach the pod.
The existing `easyauth`, `none` and `disabled` modes are unchanged.
