#!/bin/bash

# ====================================================================================
# EKS & IRSA Automation Script for the Cost-Tracker Application (Idempotent & Robust)
# ====================================================================================
# This script robustly and idempotently automates the following tasks:
# 1. Creates a new EKS cluster if it doesn't exist.
# 2. Ensures an IAM OIDC provider is associated with the cluster.
# 3. Creates the necessary IAM Policy for the cost-tracker if it doesn't exist.
# 4. Creates or updates the IAM Role with a correctly configured Trust
#    Relationship for IRSA.
# 5. Deploys/updates all necessary Kubernetes resources (ConfigMap, Secret, SA, CronJob).
#
# PREREQUISITES:
# - AWS CLI, eksctl, and kubectl must be installed and configured.
# - Your local 'secret.yaml' must exist at 'kubernetes/secret.yaml'.
# ====================================================================================

# --- Configuration ---
# Stop the script if any command fails, an unset variable is used, or a command in a pipeline fails.
set -euo pipefail

# User-configurable variables
CLUSTER_NAME="cost-tracker-cluster1"
CLUSTER_REGION="ap-southeast-2"
K8S_NAMESPACE="default" # Define namespace for clarity
K8S_SERVICE_ACCOUNT_NAME="cost-tracker-sa1"
IAM_POLICY_NAME="CostTrackerPolicy1"
IAM_ROLE_NAME="CostTrackerRole1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# --- Functions for printing pretty output ---
print_header() {
  echo ""
  echo "============================================================================="
  echo "  $1"
  echo "============================================================================="
}

print_success() {
  echo "✅  SUCCESS: $1"
}

print_info() {
  echo "ℹ️   INFO: $1"
}

# --- Step 0: Ensure EKS Cluster and OIDC Provider Exist ---
print_header "Step 0: Ensuring EKS Cluster and OIDC Provider exist"

# Check if cluster exists by describing it. Output and errors are suppressed.
if aws eks describe-cluster --name ${CLUSTER_NAME} --region ${CLUSTER_REGION} > /dev/null 2>&1; then
  print_info "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
  print_info "Cluster '${CLUSTER_NAME}' not found. Creating it now..."
  eksctl create cluster \
    --name ${CLUSTER_NAME} \
    --region ${CLUSTER_REGION} \
    --version "1.30" \
    --nodegroup-name standard-workers \
    --node-type t3.small \
    --nodes 2 \
    --with-oidc
  print_success "EKS Cluster created."
fi

# Ensure kubeconfig is pointing to the correct cluster
print_info "Updating kubeconfig for '${CLUSTER_NAME}'..."
aws eks update-kubeconfig --region ${CLUSTER_REGION} --name ${CLUSTER_NAME}

# Idempotently associate an OIDC provider.
# This will create one if it doesn't exist or do nothing if it does.
print_info "Ensuring IAM OIDC provider is associated with the cluster..."
eksctl utils associate-iam-oidc-provider --cluster ${CLUSTER_NAME} --region ${CLUSTER_REGION} --approve
print_success "IAM OIDC provider is correctly configured."

# --- Step 1: Create IAM Policy (if it doesn't exist) ---
print_header "Step 1: Ensuring IAM Policy '${IAM_POLICY_NAME}' exists"

# Define the policy document in a variable
POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ce:GetCostAndUsage","ce:ListCostCategoryDefinitions"],
      "Resource": "*"
    }
  ]
}
EOF
)

# Check if the policy already exists by listing policies and filtering by name.
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${IAM_POLICY_NAME}'].Arn" --output text)

if [ -z "$POLICY_ARN" ]; then
  print_info "IAM Policy '${IAM_POLICY_NAME}' not found. Creating it..."
  POLICY_ARN=$(aws iam create-policy \
    --policy-name ${IAM_POLICY_NAME} \
    --policy-document "${POLICY_DOCUMENT}" \
    --query 'Policy.Arn' --output text)
  print_success "IAM Policy created with ARN: ${POLICY_ARN}"
else
  print_info "IAM Policy '${IAM_POLICY_NAME}' already exists."
  print_success "Using existing IAM Policy with ARN: ${POLICY_ARN}"
fi

# --- Step 2: Create or Update IAM Role for Service Account (IRSA) ---
print_header "Step 2: Ensuring IAM Role '${IAM_ROLE_NAME}' is correctly configured"

# Get the OIDC provider URL from the cluster details
OIDC_PROVIDER=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${CLUSTER_REGION} --query "cluster.identity.oidc.issuer" --output text | sed 's|^https://||')

# Define the trust policy in a variable
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${K8S_NAMESPACE}:${K8S_SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF
)

# Check if role exists. If not, create it. If it exists, update its trust policy.
if ! aws iam get-role --role-name ${IAM_ROLE_NAME} > /dev/null 2>&1; then
  print_info "IAM Role '${IAM_ROLE_NAME}' not found. Creating it..."
  aws iam create-role \
    --role-name ${IAM_ROLE_NAME} \
    --assume-role-policy-document "${TRUST_POLICY}" > /dev/null
  print_success "IAM Role created."
else
  print_info "IAM Role '${IAM_ROLE_NAME}' already exists. Updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name ${IAM_ROLE_NAME} \
    --policy-document "${TRUST_POLICY}" > /dev/null
  print_success "IAM Role trust policy updated."
fi

# Get the Role ARN for use in annotations and policy attachment
ROLE_ARN=$(aws iam get-role --role-name ${IAM_ROLE_NAME} --query 'Role.Arn' --output text)

# Attach the policy to the role. This command is idempotent.
print_info "Attaching policy '${IAM_POLICY_NAME}' to role '${IAM_ROLE_NAME}'..."
aws iam attach-role-policy --role-name ${IAM_ROLE_NAME} --policy-arn ${POLICY_ARN}
print_success "Role setup complete. ARN: ${ROLE_ARN}"

# --- Step 3: Deploy Kubernetes Resources ---
print_header "Step 3: Deploying Kubernetes Resources using 'kubectl apply'"
# 'kubectl apply' is idempotent, so it will create or update resources as needed.

# a) ConfigMap
print_info "  - Applying ConfigMap..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cost-tracker-config
  namespace: ${K8S_NAMESPACE}
data:
  COSTTRACKER_DAYS: "30"
  AWS_REGION: "${CLUSTER_REGION}"
EOF

# b) Sealed Secret for Slack URL
print_info "  - Applying Sealed Secret for Slack webhook..."
# Check for prerequisite local secret file
if [ ! -f "kubernetes/secret.yaml" ]; then
    echo "❌ ERROR: Prerequisite file 'kubernetes/secret.yaml' not found. Aborting."
    exit 1
fi
print_info "    - Ensuring Sealed Secrets controller is installed..."
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.5/controller.yaml > /dev/null

print_info "    - Waiting for Sealed Secrets controller to be ready..."
# Wait for the deployment to be available, which is more robust than waiting for a single pod
kubectl wait --for=condition=Available --timeout=180s deployment/sealed-secrets-controller -n kube-system

print_info "    - Encrypting local 'kubernetes/secret.yaml' and applying..."
kubeseal --format=yaml < kubernetes/secret.yaml | kubectl apply -f -

# c) Service Account for IRSA
print_info "  - Applying Service Account..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${K8S_SERVICE_ACCOUNT_NAME}
  namespace: ${K8S_NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: "${ROLE_ARN}"
EOF

# d) CronJob
print_info "  - Applying CronJob..."
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cost-tracker-cronjob
  namespace: ${K8S_NAMESPACE}
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          serviceAccountName: ${K8S_SERVICE_ACCOUNT_NAME}
          containers:
          - name: cost-tracker
            image: ghcr.io/jayzsec/cost-tracker:latest
            envFrom:
            - configMapRef:
                name: cost-tracker-config
            - secretRef:
                name: cost-tracker-secret # This assumes the sealed secret creates a secret with this name
          restartPolicy: OnFailure
EOF

print_success "All Kubernetes resources applied."

# --- Step 4: Final Verification ---
print_header "Step 4: Running final verification test..."

JOB_NAME="irsa-test-run-$(date +%s)" # Use a unique name to avoid conflicts

print_info "Creating test job '${JOB_NAME}' from CronJob..."
kubectl create job ${JOB_NAME} --from=cronjob/cost-tracker-cronjob -n ${K8S_NAMESPACE}

print_info "Waiting for job's pod to start..."
# Wait up to 2 minutes for the pod associated with the job to appear
POD_NAME=""
for i in {1..24}; do
    POD_NAME=$(kubectl get pods --selector=job-name=${JOB_NAME} --namespace=${K8S_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$POD_NAME" ]; then
        print_info "Found pod: ${POD_NAME}."
        break
    fi
    sleep 5
done

if [ -z "$POD_NAME" ]; then
    echo "❌ ERROR: Timed out waiting for test pod to be created."
    kubectl delete job ${JOB_NAME} --namespace=${K8S_NAMESPACE} --ignore-not-found=true
    exit 1
fi

# Wait for the job to reach a terminal state (Succeeded or Failed) before getting logs
print_info "Waiting for job to complete..."
if ! kubectl wait --for=condition=complete --timeout=120s job/${JOB_NAME} -n ${K8S_NAMESPACE}; then
    # If the 'complete' wait fails, it might be because the job failed. Check for that.
    kubectl wait --for=condition=failed --timeout=1s job/${JOB_NAME} -n ${K8S_NAMESPACE} || true
fi

print_info "Tailing logs for pod ${POD_NAME}..."
kubectl logs --namespace=${K8S_NAMESPACE} ${POD_NAME}

# Check the final status of the pod
POD_STATUS=$(kubectl get pod ${POD_NAME} --namespace=${K8S_NAMESPACE} -o jsonpath='{.status.phase}')
print_info "Test pod finished with status: ${POD_STATUS}"

# Clean up the test job
print_info "Cleaning up test job '${JOB_NAME}'..."
kubectl delete job ${JOB_NAME} --namespace=${K8S_NAMESPACE}

if [ "$POD_STATUS" == "Succeeded" ]; then
  print_header "Setup Complete! The verification job ran successfully."
else
  echo "❌ WARNING: The verification job finished with status '${POD_STATUS}'. Please check the logs above for errors."
fi