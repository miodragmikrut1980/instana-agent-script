#!/usr/bin/env bash
# Pravi / proverava / brise test GKE Standard klaster za Instana k8s agent.
# Upotreba:  ./gke-cluster.sh create | status | delete
# Env (opciono): CLUSTER (instana-test), ZONE (europe-west1-b), NODES (2), MACHINE (e2-standard-2)
set -euo pipefail

CLUSTER="${CLUSTER:-instana-test}"
ZONE="${ZONE:-europe-west1-b}"
NODES="${NODES:-2}"
MACHINE="${MACHINE:-e2-standard-2}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ensure_tools() {
  if ! command -v gcloud >/dev/null 2>&1; then
    die "gcloud nije instaliran. Uputstvo: https://cloud.google.com/sdk/docs/install"
  fi
  if ! command -v kubectl >/dev/null 2>&1 || ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    say "Instaliram kubectl i gke-gcloud-auth-plugin (apt)..."
    sudo apt-get update -y
    sudo apt-get install -y kubectl google-cloud-cli-gke-gcloud-auth-plugin
  fi
  if ! command -v helm >/dev/null 2>&1; then
    say "Instaliram helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
  fi
}

ensure_auth() {
  local acct proj
  acct=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)
  if [[ -z "$acct" ]]; then
    die "Nema aktivnog naloga. Pokreni: gcloud auth login --no-launch-browser"
  fi
  proj=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$proj" || "$proj" == "(unset)" ]]; then
    die "Projekat nije postavljen. Pokreni: gcloud config set project ID_PROJEKTA"
  fi
  say "Nalog: ${acct}"
  say "Projekat: ${proj}"
}

cmd_create() {
  ensure_tools
  ensure_auth
  say "Ukljucujem container.googleapis.com..."
  gcloud services enable container.googleapis.com
  say "Pravim klaster ${CLUSTER} (${ZONE}, ${NODES} x ${MACHINE}), traje oko 5 min..."
  gcloud container clusters create "$CLUSTER" \
    --zone "$ZONE" \
    --num-nodes "$NODES" \
    --machine-type "$MACHINE" \
    --disk-size 50
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE"
  kubectl get nodes
  helm version --short
  say "Gotovo. Brisanje kad zavrsis: ./gke-cluster.sh delete"
}

cmd_status() {
  ensure_auth
  gcloud container clusters list
  if command -v kubectl >/dev/null 2>&1; then
    kubectl get nodes || true
  fi
}

cmd_delete() {
  ensure_auth
  local ans
  read -r -p "Obrisati klaster ${CLUSTER} (${ZONE})? [y/N]: " ans
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    say "Prekinuto."
    exit 0
  fi
  gcloud container clusters delete "$CLUSTER" --zone "$ZONE" --quiet
  say "Provera ostataka (liste treba da su prazne; diskovi VM-a ne ulaze u filter):"
  gcloud container clusters list
  gcloud compute disks list --filter="name~gke-${CLUSTER}"
  gcloud compute forwarding-rules list
}

case "${1:-}" in
  create) cmd_create ;;
  status) cmd_status ;;
  delete) cmd_delete ;;
  *) die "Upotreba: $0 create | status | delete" ;;
esac
