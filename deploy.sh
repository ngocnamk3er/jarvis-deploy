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
kubectl apply -f "$ROOT/shared/base/00-namespace.yaml"

echo "==> 3/4  Secrets (reusing local .env files from each app repo, if present as siblings)"
set -a
# shellcheck disable=SC1091
[ -f "$ROOT/../jarvis-backend/.env" ] && source "$ROOT/../jarvis-backend/.env"
# shellcheck disable=SC1091
[ -f "$ROOT/../jarvis-frontend/.env.local" ] && source "$ROOT/../jarvis-frontend/.env.local"
set +a

# Langfuse's secrets are generated here rather than read from a .env, and
# unlike every other value in this script they must survive a re-run:
# ENCRYPTION_KEY decrypts the API keys Langfuse has already written to its
# Postgres rows, so regenerating it would lock the install out of its own
# project with no error message that says so. Hence read-back-then-generate
# instead of a plain default.
lf_keep() {  # lf_keep <key> <generator>   — existing value, else generate one
  local existing
  existing=$(kubectl get secret langfuse-secrets -n "$NS" -o "jsonpath={.data.$1}" 2>/dev/null || true)
  if [ -n "$existing" ]; then printf '%s' "$existing" | base64 -d; else eval "$2"; fi
}

LF_ENCRYPTION_KEY=$(lf_keep ENCRYPTION_KEY 'openssl rand -hex 32')
LF_NEXTAUTH_SECRET=$(lf_keep NEXTAUTH_SECRET 'openssl rand -base64 32')
LF_SALT=$(lf_keep SALT 'openssl rand -base64 32')
LF_CLICKHOUSE_PASSWORD=$(lf_keep CLICKHOUSE_PASSWORD 'openssl rand -hex 16')
# The project API keys. Generated here, before Langfuse has ever run, so
# that LANGFUSE_INIT_* (see langfuse/base/langfuse.yaml) can create the
# project holding exactly these keys and jarvis-backend below can be given
# them in the same breath — no clicking through the UI to find out what they
# turned out to be.
LF_PUBLIC_KEY=$(lf_keep LANGFUSE_INIT_PROJECT_PUBLIC_KEY 'echo "pk-lf-$(uuidgen)"')
LF_SECRET_KEY=$(lf_keep LANGFUSE_INIT_PROJECT_SECRET_KEY 'echo "sk-lf-$(uuidgen)"')

kubectl create secret generic langfuse-secrets -n "$NS" \
  --from-literal=DATABASE_URL="postgresql://jarvis:jarvis@postgres.jarvis.svc.cluster.local:5432/langfuse" \
  --from-literal=ENCRYPTION_KEY="$LF_ENCRYPTION_KEY" \
  --from-literal=NEXTAUTH_SECRET="$LF_NEXTAUTH_SECRET" \
  --from-literal=SALT="$LF_SALT" \
  --from-literal=CLICKHOUSE_PASSWORD="$LF_CLICKHOUSE_PASSWORD" \
  --from-literal=LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID="${MINIO_ROOT_USER:-jarvis}" \
  --from-literal=LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD:-jarvis-minio-dev-only}" \
  --from-literal=LANGFUSE_INIT_PROJECT_PUBLIC_KEY="$LF_PUBLIC_KEY" \
  --from-literal=LANGFUSE_INIT_PROJECT_SECRET_KEY="$LF_SECRET_KEY" \
  --from-literal=LANGFUSE_INIT_USER_EMAIL="admin@jarvis.local" \
  --from-literal=LANGFUSE_INIT_USER_NAME="admin" \
  --from-literal=LANGFUSE_INIT_USER_PASSWORD="${LANGFUSE_ADMIN_PASSWORD:-jarvis-langfuse-dev-only}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic jarvis-secrets -n "$NS" \
  --from-literal=OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
  --from-literal=TAVILY_API_KEY="${TAVILY_API_KEY:-}" \
  --from-literal=DATABASE_URL="postgresql://jarvis:jarvis@postgres.jarvis.svc.cluster.local:5432/jarvis" \
  --from-literal=ADMIN_DATABASE_URL="postgresql://jarvis:jarvis@postgres.jarvis.svc.cluster.local:5432/postgres" \
  --from-literal=CONVERSATION_DATABASE_URL="postgresql://jarvis:jarvis@postgres.jarvis.svc.cluster.local:5432/jarvis_conversations" \
  --from-literal=FILE_DATABASE_URL="postgresql://jarvis:jarvis@postgres.jarvis.svc.cluster.local:5432/jarvis_files" \
  --from-literal=INTERNAL_API_KEY="${INTERNAL_API_KEY:-changeme-dev-only}" \
  --from-literal=MINIO_ROOT_USER="${MINIO_ROOT_USER:-jarvis}" \
  --from-literal=MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-jarvis-minio-dev-only}" \
  --from-literal=EMBEDDING_API_KEY="${EMBEDDING_API_KEY:-}" \
  --from-literal=LANGFUSE_PUBLIC_KEY="$LF_PUBLIC_KEY" \
  --from-literal=LANGFUSE_SECRET_KEY="$LF_SECRET_KEY" \
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

echo "==> 4/4  Registering this repo's Applications with ArgoCD"
# One Application per service (backend/frontend/keycloak/conversation-service)
# plus one for shared resources (namespace/configmap/postgres/ingress) — each
# syncs independently, so a bump commit from one app's Jenkinsfile only
# touches that app's own Application, not the others. This also applies the
# staging-* Applications in this directory, but (like before) this script
# only waits on the test-cluster ones below — the staging cluster may not
# even be up yet during a fresh bootstrap.
kubectl apply -f "$ROOT/argocd/"
for app in jarvis-shared jarvis-backend jarvis-frontend jarvis-keycloak jarvis-conversation-service jarvis-file-service jarvis-langfuse; do
  kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced "application/${app}" --timeout=120s
done

MINIKUBE_IP=$(minikube ip)
cat <<EOF

Done. ArgoCD now owns rolling out namespace/configmap/Postgres/Keycloak/
backend/frontend/ingress from this repo (see argocd/*.yaml) — no more
manual kubectl apply needed for those.

Add this to /etc/hosts:

  ${MINIKUBE_IP}  jarvis.local api.jarvis.local auth.jarvis.local langfuse.jarvis.local

Then open:
  http://jarvis.local        (app)
  http://api.jarvis.local    (backend API)
  http://auth.jarvis.local   (Keycloak)
  http://langfuse.jarvis.local  (Langfuse traces — admin@jarvis.local)
EOF
