#!/usr/bin/env bash
set -euo pipefail

# ---------- Config (overridable) ----------
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-geo-demo}"
WHO="$(whoami 2>/dev/null || echo user)"
BUCKET="${BUCKET:-${WHO}-geo-demo-uploads}"
NS="geo"
PROFILE_FLAG=${AWS_PROFILE:+--profile "$AWS_PROFILE"}

say() { printf "\n\033[1;36m[BOOTSTRAP]\033[0m %s\n" "$*"; }
create_irsa() {
  # args: namespace name policy_arn
  local _ns="$1" _name="$2" _pol="$3"
  say "Creating IRSA for ${_ns}/${_name} (policy=${_pol}) via eksctl…"
  if eksctl create iamserviceaccount \
    --cluster "$CLUSTER" \
    --region "$AWS_REGION" \
    --namespace "$_ns" \
    --name "$_name" \
    --attach-policy-arn "$_pol" \
    --override-existing-serviceaccounts \
    --approve; then
    return 0
  fi

  say "eksctl IRSA failed; falling back to manual IRSA (IAM role + SA annotation)."

  # OIDC issuer
  local OIDC_ISSUER
  OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" $PROFILE_FLAG \
                 --query 'cluster.identity.oidc.issuer' --output text)"
  local OIDC_ISSUER_HOST="${OIDC_ISSUER#https://}"
  local ACCOUNT_ID
  ACCOUNT_ID="$(aws sts get-caller-identity $PROFILE_FLAG --query Account --output text)"

  # Trust policy (inline JSON, no temp files)
  local TRUST_JSON
  TRUST_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam::'"$ACCOUNT_ID"':oidc-provider/'"$OIDC_ISSUER_HOST"'"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"'"$OIDC_ISSUER_HOST"':aud":"sts.amazonaws.com","'"$OIDC_ISSUER_HOST"':sub":"system:serviceaccount:'"$_ns"':'"$_name"'"}}}]}'

  local ROLE_NAME="${CLUSTER}-${_ns}-${_name}-irsa"
  local ROLE_ARN
  ROLE_ARN="$(aws iam get-role $PROFILE_FLAG --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || echo "")"
  if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" = "None" ]; then
    ROLE_ARN="$(aws iam create-role $PROFILE_FLAG \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "$TRUST_JSON" \
      --query 'Role.Arn' --output text)"
  else
    aws iam update-assume-role-policy $PROFILE_FLAG --role-name "$ROLE_NAME" --policy-document "$TRUST_JSON" >/dev/null
  fi

  # Attach policy & annotate SA
  aws iam attach-role-policy $PROFILE_FLAG --role-name "$ROLE_NAME" --policy-arn "$_pol" >/dev/null 2>&1 || true
  kubectl get sa "$_name" -n "$_ns" >/dev/null 2>&1 || kubectl create sa "$_name" -n "$_ns"
  kubectl annotate sa "$_name" -n "$_ns" eks.amazonaws.com/role-arn="$ROLE_ARN" --overwrite
}

say "Using region=$AWS_REGION cluster=$CLUSTER bucket=$BUCKET namespace=$NS profile=${AWS_PROFILE:-<default>}"

# ---------- S3 bucket (idempotent) ----------
if aws s3api head-bucket --bucket "$BUCKET" $PROFILE_FLAG 2>/dev/null; then
  say "S3 bucket $BUCKET already exists, skipping"
else
  say "Creating S3 bucket $BUCKET"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" $PROFILE_FLAG
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" $PROFILE_FLAG
  fi
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled $PROFILE_FLAG
fi

# ---------- EKS cluster (idempotent) ----------
if aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" $PROFILE_FLAG >/dev/null 2>&1; then
  say "Cluster $CLUSTER already exists, skipping creation"
else
  say "Creating cluster from infra/cluster.yaml"
  eksctl create cluster -f infra/cluster.yaml
fi

# ---------- Kubeconfig & reachability (non-destructive) ----------
say "Checking current kubectl context reachability"
PROFILE_FLAG=${AWS_PROFILE:+--profile "$AWS_PROFILE"}

# Show what context we're on right now (useful on Windows/Git Bash)
CUR_CTX="$(kubectl config current-context 2>/dev/null || true)"
say "Current kubectl context: ${CUR_CTX:-<none>}"

# If current context is already good, keep it
if kubectl cluster-info >/dev/null 2>&1; then
  say "Current kubectl context is reachable; keeping it (no overwrite)."
else
  say "Current context not reachable; updating kubeconfig for $CLUSTER in $AWS_REGION (profile=${AWS_PROFILE:-<default>})"
  aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" $PROFILE_FLAG --alias "$CLUSTER" >/dev/null
  kubectl config use-context "$CLUSTER" >/dev/null 2>&1 || true
fi

# ---------- Verifying API reachability (ultra-compatible) ----------
echo "[BOOTSTRAP] Verifying API reachability..."
tries=0
while true; do
  kubectl -n kube-system get pods >/dev/null 2>&1
  ks=$?
  kubectl get nodes >/dev/null 2>&1
  kn=$?

  if [ "$ks" -eq 0 ] && [ "$kn" -eq 0 ]; then
    ctx=kubectl config current-context 2>/dev/null || echo none
    break
  fi

  tries=expr "$tries" + 1
  if [ "$tries" -ge 10 ]; then
    pub=`aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" $PROFILE_FLAG \
      --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text 2>/dev/null || echo Unknown`
    priv=`aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" $PROFILE_FLAG \
      --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' --output text 2>/dev/null || echo Unknown`
    ctx=kubectl config current-context 2>/dev/null || echo none
    echo "[BOOTSTRAP] ERROR: kubectl cannot reach the API server after retries."
    echo "  Cluster=$CLUSTER  Region=$AWS_REGION  Profile=${AWS_PROFILE:-<default>}  Context=$ctx"
    echo "  PublicAccess=$pub  PrivateAccess=$priv"
    echo "  Tip: export AWS_PROFILE=<your-profile> and re-run: AWS_PROFILE=\$AWS_PROFILE ./infra/bootstrap.sh"
    exit 1
  fi

  sleep 3
done

# ---------- Namespace ----------
kubectl get namespace "$NS" >/dev/null 2>&1 || { say "Creating namespace $NS"; kubectl create namespace "$NS"; }

# ---------- Associate OIDC (safe to re-run) ----------
say "Associating IAM OIDC provider"
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER" --region "$AWS_REGION" --approve

# ---------- AWS Load Balancer Controller IRSA ----------
# Use AWS-managed policy to avoid JSON policy headaches.
ALB_POLICY_ARN="arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy"

clean_failed_stacks() {
  local pat="$1"
  local stacks
  stacks=$(aws cloudformation list-stacks \
    --stack-status-filter CREATE_FAILED ROLLBACK_FAILED ROLLBACK_COMPLETE DELETE_FAILED \
    --query "StackSummaries[?contains(StackName,\$pat\)].StackName" --output text $PROFILE_FLAG 2>/dev/null || true)
  [ -z "${stacks:-}" ] || [ "$stacks" = "None" ] && return 0
  say "Deleting failed stacks: $stacks"
  for s in $stacks; do aws cloudformation delete-stack --stack-name "$s" $PROFILE_FLAG; done
  for s in $stacks; do aws cloudformation wait stack-delete-complete --stack-name "$s" $PROFILE_FLAG || true; done
}

say "Ensuring IRSA for aws-load-balancer-controller"
kubectl -n kube-system delete sa aws-load-balancer-controller --ignore-not-found >/dev/null 2>&1 || true
clean_failed_stacks "iamserviceaccount-kube-system-aws-load-balancer-controller"

eksctl create iamserviceaccount \
  --cluster "$CLUSTER" \
  --region "$AWS_REGION" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn "$ALB_POLICY_ARN" \
  --override-existing-serviceaccounts \
  --approve

say "Installing/Upgrading AWS Load Balancer Controller via Helm"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# ---------------- App IRSA (S3) — no temp files ----------------
say "Ensuring IRSA for app to access S3 ($BUCKET)"
APP_POLICY_NAME="${CLUSTER}-s3-upload-policy"
APP_POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::'"$BUCKET"'"]},{"Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::'"$BUCKET"'/*"]}]}'

APP_POLICY_ARN="$(aws iam list-policies --scope Local $PROFILE_FLAG \
  --query "Policies[?PolicyName=='$APP_POLICY_NAME'].Arn" --output text 2>/dev/null || echo "")"
if [ -z "$APP_POLICY_ARN" ] || [ "$APP_POLICY_ARN" = "None" ]; then
  say "Creating customer-managed policy $APP_POLICY_NAME"
  APP_POLICY_ARN="$(aws iam create-policy $PROFILE_FLAG --policy-name "$APP_POLICY_NAME" \
     --policy-document "$APP_POLICY_JSON" --query 'Policy.Arn' --output text)"
else
  say "Policy $APP_POLICY_NAME already exists, ARN: $APP_POLICY_ARN"
fi

# Clean any failed CFN stacks for app-sa
CFN_LIST2=$(aws cloudformation list-stacks $PROFILE_FLAG \
  --stack-status-filter CREATE_FAILED ROLLBACK_FAILED ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?contains(StackName,'iamserviceaccount-${NS}-app-sa')].StackName" \
  --output text 2>/dev/null || true)
if [ -n "${CFN_LIST2:-}" ] && [ "$CFN_LIST2" != "None" ]; then
  for s in $CFN_LIST2; do aws cloudformation delete-stack $PROFILE_FLAG --stack-name "$s" || true; done
  for s in $CFN_LIST2; do aws cloudformation wait stack-delete-complete $PROFILE_FLAG --stack-name "$s" || true; done
fi

# Ensure namespace exists and create IRSA
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
create_irsa "$NS" "app-sa" "$APP_POLICY_ARN"

# Recreate/ensure the ServiceAccount with this IAM policy (IRSA)
kubectl -n "$NS" delete sa app-sa --ignore-not-found >/dev/null 2>&1 || true
eksctl create iamserviceaccount --cluster "$CLUSTER" --region "$AWS_REGION" --namespace "$NS" --name app-sa --attach-policy-arn "$APP_POLICY_ARN" --override-existing-serviceaccounts --approve
echo "  export AWS_REGION=$AWS_REGION"
echo "  export CLUSTER=$CLUSTER"
echo "  export BUCKET=$BUCKET"
echo "  export AWS_PROFILE=${AWS_PROFILE:-<default>}"
