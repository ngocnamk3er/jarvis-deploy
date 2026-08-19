#!/usr/bin/env bash
# Deploy the full Jarvis stack (Postgres x2, Keycloak, backend, frontend)
# to a local minikube cluster. Idempotent — safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=jarvis

echo "==> 1/9  Ensuring minikube is running"
if ! minikube status >/dev/null 2>&1; then
  minikube start
fi
minikube addons enable ingress
echo "    waiting for ingress-nginx controller..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "==> 2/9  Building images into minikube's docker daemon"
eval "$(minikube docker-env)"
docker build -t jarvis-backend:local "$ROOT/backend"
docker build \
  --build-arg NEXT_PUBLIC_API_URL=http://api.jarvis.local \
  --build-arg NEXT_PUBLIC_KEYCLOAK_ISSUER=http://auth.jarvis.local/realms/jarvis \
  -t jarvis-frontend:local "$ROOT/frontend"
docker build -t jarvis-keycloak:local "$ROOT/keycloak"

echo "==> 3/9  Namespace"
kubectl apply -f "$ROOT/k8s/00-namespace.yaml"

echo "==> 4/9  Secrets (reusing local backend/.env + frontend/.env.local)"
set -a
# shellcheck disable=SC1091
[ -f "$ROOT/backend/.env" ] && source "$ROOT/backend/.env"
# shellcheck disable=SC1091
[ -f "$ROOT/frontend/.env.local" ] && source "$ROOT/frontend/.env.local"
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

echo "==> 5/9  ConfigMap + Postgres instances"
kubectl apply -f "$ROOT/k8s/configmap.yaml"
kubectl apply -f "$ROOT/k8s/postgres.yaml"
kubectl apply -f "$ROOT/k8s/keycloak-postgres.yaml"
kubectl -n "$NS" rollout status statefulset/postgres --timeout=120s
kubectl -n "$NS" rollout status statefulset/keycloak-postgres --timeout=120s

echo "==> 6/9  Keycloak"
kubectl apply -f "$ROOT/k8s/keycloak.yaml"
kubectl -n "$NS" rollout status deployment/keycloak --timeout=300s

echo "==> 7/9  Backend"
kubectl apply -f "$ROOT/k8s/backend.yaml"
kubectl -n "$NS" rollout status deployment/backend --timeout=180s

echo "==> 8/9  Frontend"
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.clusterIP}')
sed "s/__INGRESS_IP__/${INGRESS_IP}/" "$ROOT/k8s/frontend.yaml" | kubectl apply -f -
kubectl -n "$NS" rollout status deployment/frontend --timeout=180s

echo "==> 9/9  Ingress"
kubectl apply -f "$ROOT/k8s/ingress.yaml"

MINIKUBE_IP=$(minikube ip)
cat <<EOF

Done. Add this to /etc/hosts:

  ${MINIKUBE_IP}  jarvis.local api.jarvis.local auth.jarvis.local

Then open:
  http://jarvis.local        (app)
  http://api.jarvis.local    (backend API)
  http://auth.jarvis.local   (Keycloak)
EOF
