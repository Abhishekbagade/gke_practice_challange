#!/usr/bin/env bash
set -euo pipefail
AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=${CLUSTER:-geo-demo}
BUCKET=${BUCKET:-$USER-geo-demo-uploads}
aws s3 rm "s3://$BUCKET" --recursive || true
aws s3api delete-bucket --bucket "$BUCKET" --region "$AWS_REGION" || true
eksctl delete cluster --name "$CLUSTER" --region "$AWS_REGION"
