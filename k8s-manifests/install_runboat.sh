#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Script functions ---
command_exists () {
  command -v "$1" &>/dev/null
}

wait_for_resource () {
  local resource_type="$1"
  local resource_label="$2"
  local namespace="$3"
  echo "Waiting for $resource_type with label $resource_label in namespace $namespace to be ready..."
  microk8s kubectl wait --for=condition=ready "$resource_type" -l "$resource_label" -n "$namespace" --timeout=300s || { echo "Error: $resource_type with label $resource_label is not ready. Exiting."; exit 1; }
}

# --- 1. Validate script execution and get user info ---
echo "--- Initializing Setup Script ---"
# Check if the script is being run with sudo.
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run with sudo. Please run it as: sudo $0"
  exit 1
fi

# Get the original user who ran the script, not the 'root' user.
TARGET_USER=$SUDO_USER
# Find the home directory of the target user.
TARGET_USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

echo "Script is running with sudo. Targeting permissions and files for user '$TARGET_USER' in home directory '$TARGET_USER_HOME'."

# --- 2. Install MicroK8s ---
echo "--- Installing MicroK8s ---"
if ! command_exists microk8s; then
    echo "MicroK8s not found. Installing now..."
    sudo snap install microk8s --classic || { echo "Error: Failed to install MicroK8s. Exiting."; exit 1; }
else
    echo "MicroK8s is already installed."
fi
echo "Waiting for MicroK8s to be ready..."
microk8s status --wait-ready || { echo "Error: MicroK8s is not ready. Exiting."; exit 1; }

# --- 3. Configure kubeconfig and permissions ---
echo "--- Configuring Kubeconfig and Permissions for $TARGET_USER ---"
# Create the .kube directory and set ownership.
sudo -u "$TARGET_USER" mkdir -p "$TARGET_USER_HOME/.kube" || { echo "Error: Failed to create .kube directory."; exit 1; }
# Generate kubeconfig and write it to the target user's home directory.
sudo microk8s config | sudo -u "$TARGET_USER" tee "$TARGET_USER_HOME/.kube/config" > /dev/null
sudo chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_USER_HOME/.kube" || { echo "Error: Failed to set ownership of ~/.kube."; exit 1; }

# Add the target user to the microk8s group.
if ! groups "$TARGET_USER" | grep -q microk8s; then
    echo "Adding user '$TARGET_USER' to the 'microk8s' group..."
    sudo usermod -a -G microk8s "$TARGET_USER"
    echo "Permissions updated. For changes to take effect, '$TARGET_USER' must log out and log back in."
else
    echo "User '$TARGET_USER' is already in the 'microk8s' group."
fi

# --- 4. Enable required add-ons sequentially ---
echo "--- Enabling MicroK8s add-ons ---"
declare -a addons=("dns" "hostpath-storage" "community" "helm" "cloudnative-pg" "ingress")
for addon in "${addons[@]}"; do
    echo "Enabling $addon..."
    microk8s enable "$addon" || { echo "Error: Failed to enable addon '$addon'. Exiting."; exit 1; }
done
echo "All necessary add-ons are enabled."

# --- 5. Install kubectl and set aliases ---
echo "--- Installing and configuring kubectl and helm ---"
if ! command_exists kubectl; then
    sudo snap install kubectl --classic || { echo "Error: Failed to install kubectl. Exiting."; exit 1; }
fi

# Add aliases to the user's .bashrc for persistent use.
echo "Adding aliases to ~/.bashrc for persistent use."
echo "alias kubectl='microk8s kubectl'" | sudo -u "$TARGET_USER" tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
echo "alias helm='microk8s helm'" | sudo -u "$TARGET_USER" tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
echo "Aliases have been added. Run 'source ~/.bashrc' or restart your terminal to use them."

# --- 6. Install Cert-Manager via Helm (Idempotent) ---
echo "--- Installing/Upgrading Cert-Manager ---"
sudo -u "$TARGET_USER" microk8s helm repo add jetstack https://charts.jetstack.io || { echo "Error: Failed to add Jetstack Helm repo. Exiting."; exit 1; }
sudo -u "$TARGET_USER" microk8s helm repo update || { echo "Error: Failed to update Helm repos. Exiting."; exit 1; }
sudo -u "$TARGET_USER" microk8s kubectl create namespace cert-manager --dry-run=client -o yaml | sudo -u "$TARGET_USER" microk8s kubectl apply -f -
sudo -u "$TARGET_USER" microk8s helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.14.5 --set installCRDs=true || { echo "Error: Failed to install/upgrade Cert-Manager. Exiting."; exit 1; }
wait_for_resource "pods" "app.kubernetes.io/instance=cert-manager" "cert-manager"
echo "Cert-Manager is ready."

# --- 7. Configure NGINX Ingress Controller DaemonSet ---
echo "--- Patching NGINX Ingress Controller DaemonSet to use ConfigMap ---"
PATCH_ARG='--configmap=$(POD_NAMESPACE)/nginx-configuration'
if sudo -u "$TARGET_USER" microk8s kubectl get daemonset nginx-ingress-microk8s-controller -n ingress -o=jsonpath='{.spec.template.spec.containers[?(@.name=="nginx-ingress-microk8s-controller")].args}' | grep -q "$PATCH_ARG"; then
    echo "ConfigMap argument already exists. Skipping patch."
else
    sudo -u "$TARGET_USER" microk8s kubectl patch daemonset nginx-ingress-microk8s-controller -n ingress --type=json -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--configmap=$(POD_NAMESPACE)/nginx-configuration"}]' || { echo "Error: Failed to patch NGINX Ingress Controller DaemonSet. Exiting."; exit 1; }
    echo "DaemonSet patched. Rolling out pods to apply changes."
    microk8s kubectl rollout status daemonset/nginx-ingress-microk8s-controller -n ingress --timeout=300s
fi

# --- 8. Apply manifests from current directory ---
echo "--- Applying Kubernetes manifests from current directory ---"
echo "Using current directory: $PWD"

echo "Creating namespaces from 00-runboat-namespaces.yaml."
sudo -u "$TARGET_USER" microk8s kubectl apply -f 00-runboat-namespaces.yaml || { echo "Error: Failed to apply namespace manifests. Exiting."; exit 1; }

echo "Creating 'runboat-secrets' from runboat-secrets.env."
if [ ! -f "runboat-secrets.env" ]; then
    echo "Error: The 'runboat-secrets.env' file was not found. Exiting."; exit 1; fi
sudo -u "$TARGET_USER" microk8s kubectl create secret generic runboat-secrets --from-env-file=runboat-secrets.env -n runboat --dry-run=client -o yaml | sudo -u "$TARGET_USER" microk8s kubectl apply -f -
sudo -u "$TARGET_USER" microk8s kubectl create secret generic runboat-secrets --from-env-file=runboat-secrets.env -n runboat-builds --dry-run=client -o yaml | sudo -u "$TARGET_USER" microk8s kubectl apply -f -
echo "Secrets created successfully."

echo "Applying all Kubernetes manifests in the current directory."
sudo -u "$TARGET_USER" microk8s kubectl apply -f . || { echo "Error: Failed to apply manifests. Exiting."; exit 1; }
echo "All manifests applied successfully."

echo ""
echo "--- Setup is Complete ---"
echo "Your MicroK8s environment is configured."
echo ""
echo "Next steps:"
echo "1. Log out and log back in to fully enable your new permissions."
echo "2. Monitor your pods with: 'kubectl get all -A'"
echo "3. Troubleshoot any issues by checking pod logs: 'kubectl logs <pod-name> -n <namespace>'"
