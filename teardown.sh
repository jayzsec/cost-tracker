#!/bin/bash

# =============================================================================
# EKS & IRSA Teardown Script for the Cost-Tracker Application
# =============================================================================
# This script tears down all resources created by the setup script:
# 1. Deletes all related Kubernetes resources.
# 2. Detaches and deletes the IAM Policy for the cost-tracker.
# 3. Deletes the IAM Role used for IRSA.
# 4. Deletes the entire EKS cluster and its associated node groups/VPC.
#
# PREREQUISITES:
# - AWS CLI, eksctl, and kubectl must be installed and configured.
# =============================================================================

# --- Configuration ---
# Stop the script if any command fails, an unset variable is used, or a command in a pipeline fails.
set -euo pipefail

# User-configurable variables (MUST MATCH YOUR SETUP SCRIPT)
CLUSTER_NAME="cost-tracker-cluster"
CLUSTER_REGION="ap-southeast-2"
K8S_NAMESPACE="default"
K8S_SERVICE_ACCOUNT_NAME="cost-tracker-sa"
IAM_POLICY_NAME="CostTrackerPolicy"
IAM_ROLE_NAME="CostTrackerRole"
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

# --- DANGER: Confirmation Prompt ---
print_header "!! WARNING: DESTRUCTIVE ACTION AHEAD !!"
echo "This script will tear down all resources for the '${CLUSTER_NAME}' application."
echo "This includes the EKS Cluster, IAM Role, IAM Policy, and all Kubernetes objects."
echo "This action is irreversible."
echo ""
read -p "Are you absolutely sure you want to delete cluster '${CLUSTER_NAME}'? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Teardown aborted by user."
    exit 1
fi

# --- Step 1: Delete Kubernetes Resources ---
print_header "Step 1: Deleting Kubernetes Resources"

# Update kubeconfig to ensure we're targeting the correct cluster, if it exists
if aws eks describe-cluster --name ${CLUSTER_NAME} --region ${CLUSTER_REGION} > /dev/null 2>&1; then
    print_info "Pointing kubectl to '${CLUSTER_NAME}'..."
    aws eks update-kubeconfig --region ${CLUSTER_REGION} --name ${CLUSTER_NAME}

    # Using --ignore-not-found=true makes the commands idempotent for deletion.
    print_info "Deleting CronJob, Service Account, ConfigMap, and Secrets..."
    kubectl delete cronjob cost-tracker-cronjob -n ${K8S_NAMESPACE} --ignore-not-found=true
    kubectl delete serviceaccount ${K8S_SERVICE_ACCOUNT_NAME} -n ${K8S_NAMESPACE} --ignore-not-found=true
    kubectl delete configmap cost-tracker-config -n ${K8S_NAMESPACE} --ignore-not-found=true
    # The Sealed Secret controller creates a regular Secret. We delete both.
    kubectl delete secret cost-tracker-secret -n ${K8S_NAMESPACE} --ignore-not-found=true
    kubectl delete sealedsecret cost-tracker-secret -n ${K8S_NAMESPACE} --ignore-not-found=true

    print_info "Deleting the Sealed Secrets controller..."
    # Note: This might be a shared resource. If other apps use it, you can comment this out.
    kubectl delete -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.5/controller.yaml --ignore-not-found=true
    
    print_success "Kubernetes application resources deleted."
else
    print_info "Cluster '${CLUSTER_NAME}' not found. Skipping deletion of Kubernetes resources."
fi


# --- Step 2: Delete IAM Role and Policy ---
print_header "Step 2: Deleting IAM Role and Policy"
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${IAM_POLICY_NAME}'].Arn" --output text)

# Check if role exists before trying to detach/delete
if aws iam get-role --role-name ${IAM_ROLE_NAME} > /dev/null 2>&1; then
    # Detach the policy from the role, if the policy exists
    if [ -n "$POLICY_ARN" ]; then
        print_info "Detaching policy '${IAM_POLICY_NAME}' from role '${IAM_ROLE_NAME}'..."
        aws iam detach-role-policy --role-name ${IAM_ROLE_NAME} --policy-arn ${POLICY_ARN} || print_info "Policy was not attached. Continuing."
    fi
    # Delete the role
    print_info "Deleting role '${IAM_ROLE_NAME}'..."
    aws iam delete-role --role-name ${IAM_ROLE_NAME}
    print_success "Role '${IAM_ROLE_NAME}' deleted."
else
    print_info "Role '${IAM_ROLE_NAME}' not found. Skipping."
fi

# Delete the policy itself, if it exists
if [ -n "$POLICY_ARN" ]; then
    print_info "Deleting policy '${IAM_POLICY_NAME}'..."
    # Note: This will fail if the policy is attached to other entities. This is a safety feature.
    aws iam delete-policy --policy-arn ${POLICY_ARN}
    print_success "Policy '${IAM_POLICY_NAME}' deleted."
else
    print_info "Policy '${IAM_POLICY_NAME}' not found. Skipping."
fi


# --- Step 3: Delete the EKS Cluster ---
print_header "Step 3: Deleting EKS Cluster '${CLUSTER_NAME}'"
# Check if the cluster exists with eksctl
if eksctl get cluster --name ${CLUSTER_NAME} --region ${CLUSTER_REGION} > /dev/null 2>&1; then
    print_info "Cluster '${CLUSTER_NAME}' found. Initiating deletion (this may take 15-20 minutes)..."
    eksctl delete cluster --name ${CLUSTER_NAME} --region ${CLUSTER_REGION}
    print_success "Cluster '${CLUSTER_NAME}' and its associated resources have been deleted."
else
    print_info "Cluster '${CLUSTER_NAME}' not found. Skipping."
fi

print_header "Teardown Complete!"