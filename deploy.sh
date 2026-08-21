#!/usr/bin/env bash
# One-time bootstrap for the Jarvis stack on a local minikube cluster:
# cluster/ingress, secrets (never GitOps-managed — see kustomization.yaml),
# and registering this repo with ArgoCD. Everything else (namespace,
# configmap, Postgres, Keycloak, backend, frontend, ingress) is applied
# automatically by ArgoCD once the Application below is registered — this
# script no longer builds or applies those directly (backend/frontend/
# keycloak now live in their own repos with their own Jenkins pipelines;
# see jarvis-backend, jarvis-frontend, jarvis-keycloak).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=jarvis

echo "==> 1/4  Ensuring minikube is running"
if ! minikube status >/dev/null 2>&1; then
  minikube start
fi
minikube addons enable ingress
echo "    waiting for ingress-nginx controller..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "==> 2/4  Namespace"
kubectl apply -f "$ROOT/00-namespace.yaml"

echo "==> 3/4  Secrets (reusing local .env files from each app repo, if present as siblings)"
set -a
# shellcheck disable=SC1091
[ -f "$ROOT/../jarvis-backend/.env" ] && source "$ROOT/../jarvis-backend/.env"
# shellcheck disable=SC1091
[ -f "$ROOT/../jarvis-frontend/.env.local" ] && source "$ROOT/../jarvis-frontend/.env.local"
set +a

kubectl create secret generic jarvis-secrets -n "$NS" \
  --from-literal=OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
  --from-literal=TAVILY_API_KEY="${TAVILY_API_KEY:-}" \
  --from-literal=DATABASE_URL="postgresql://jarvis:jarvis@postgres.jarvis.svc.cluster.local:5432/jarvis" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic jarvis-frontend-secrets -n "$NS" \
  --from-literal=AUTH_SECRET="${AUTH_SECRET:-}" \
  --from-literal=AUTH_KEYCLOAK_ID="jarvis-frontend" \
  --from-literal=AUTH_KEYCLOAK_SECRET="${AUTH_KEYCLOAK_SECRET:-}" \
  --from-literal=AUTH_KEYCLOAK_ISSUER="http://auth.jarvis.local/realms/jarvis" \
  --dry-run=client -o yaml | kubectl apply -f -

# Matches keycloak/docker-compose.yml's existing dev-default values.
kubectl create secret generic jarvis-keycloak-secrets -n "$NS" \
  --from-literal=KC_BOOTSTRAP_ADMIN_USERNAME="admin" \
  --from-literal=KC_BOOTSTRAP_ADMIN_PASSWORD="admin" \
  --from-literal=KC_DB_USERNAME="keycloak" \
  --from-literal=KC_DB_PASSWORD="keycloak" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry gitlab-registry-creds -n "$NS" \
  --docker-server="host.minikube.internal:5050" \
  --docker-username="root" \
  --docker-password="${GITLAB_REGISTRY_TOKEN:?set GITLAB_REGISTRY_TOKEN to a GitLab access token with read_registry scope}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount default -n "$NS" \
  -p '{"imagePullSecrets": [{"name": "gitlab-registry-creds"}]}'

echo "==> 4/4  Registering this repo's 4 Applications with ArgoCD"
# One Application per service (backend/frontend/keycloak) plus one for
# shared resources (namespace/configmap/postgres/ingress) — each syncs
# independently, so a bump commit from one app's Jenkinsfile only touches
# that app's own Application, not the others.
kubectl apply -f "$ROOT/argocd/"
for app in jarvis-shared jarvis-backend jarvis-frontend jarvis-keycloak; do
  kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced "application/${app}" --timeout=120s
done

MINIKUBE_IP=$(minikube ip)
cat <<EOF

Done. ArgoCD now owns rolling out namespace/configmap/Postgres/Keycloak/
backend/frontend/ingress from this repo (see argocd/*.yaml) — no more
manual kubectl apply needed for those.

Add this to /etc/hosts:

  ${MINIKUBE_IP}  jarvis.local api.jarvis.local auth.jarvis.local

Then open:
  http://jarvis.local        (app)
  http://api.jarvis.local    (backend API)
  http://auth.jarvis.local   (Keycloak)
EOF
