#!/usr/bin/env bash
# sample_eks_auto_fixed_v2.sh
# Creates minimal VPC + EKS Auto Mode cluster (general-purpose + system), sleeps 30s, then deletes.
# - Uses --cli-input-json to pass a full API payload (avoids shell parsing problems).
# - Detects existing IAM roles.
# - Disables AWS CLI pager (no blocking).
export AWS_PAGER=""

REGION="ap-south-1"                    # change if needed
ACCOUNT_ID="681802563986"
CLUSTER_NAME="auto-demo-cluster-$$"    # unique-ish
CIDR_VPC="10.0.0.0/16"
CIDR_SUBNET1="10.0.1.0/24"
CIDR_SUBNET2="10.0.2.0/24"

# Track created resources for cleanup
VPC_ID=""
IGW_ID=""
SUBNET1=""
SUBNET2=""
RT_ID=""
CLUSTER_CREATED=false

cleanup() {
  echo "CLEANUP: starting best-effort cleanup..."
  set +e
  if $CLUSTER_CREATED; then
    echo "Deleting EKS cluster ${CLUSTER_NAME} ..."
    aws eks delete-cluster --name "$CLUSTER_NAME" --region "$REGION" || true
  fi

  [[ -n "$SUBNET1" ]] && aws ec2 delete-subnet --subnet-id "$SUBNET1" --region "$REGION" || true
  [[ -n "$SUBNET2" ]] && aws ec2.delete-subnet --subnet-id "$SUBNET2" --region "$REGION" || true

  if [[ -n "$IGW_ID" && -n "$VPC_ID" ]]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" || true
  fi

  [[ -n "$RT_ID" ]] && aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$REGION" || true
  [[ -n "$VPC_ID" ]] && aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" || true

  # Detach & delete IAM roles if they were created (best effort)
  for r in AmazonEKSAutoClusterRole AmazonEKSAutoNodeRole; do
    aws iam list-attached-role-policies --role-name "$r" --region "$REGION" --output text --query 'AttachedPolicies[*].PolicyArn' \
      | xargs -r -n1 -I{} aws iam detach-role-policy --role-name "$r" --policy-arn {} --region "$REGION" || true
    aws iam delete-role --role-name "$r" --region "$REGION" || true
  done

  echo "CLEANUP done."
}
trap cleanup EXIT

echo "==> Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block "$CIDR_VPC" --region "$REGION" --query 'Vpc.VpcId' --output text)
echo "VPC_ID=$VPC_ID"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" --region "$REGION"

echo "==> Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
echo "IGW_ID=$IGW_ID"

echo "==> Creating Subnets..."
SUBNET1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$CIDR_SUBNET1" --availability-zone "${REGION}a" --region "$REGION" --query 'Subnet.SubnetId' --output text)
SUBNET2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$CIDR_SUBNET2" --availability-zone "${REGION}b" --region "$REGION" --query 'Subnet.SubnetId' --output text)

aws ec2 modify-subnet-attribute --subnet-id "$SUBNET1" --map-public-ip-on-launch --region "$REGION"
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET2" --map-public-ip-on-launch --region "$REGION"
echo "SUBNET1=$SUBNET1 SUBNET2=$SUBNET2"

echo "==> Creating Route Table and route..."
RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$REGION"
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET1" --region "$REGION"
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET2" --region "$REGION"
echo "RT_ID=$RT_ID"

# ---------------- IAM roles (create-if-not-exists) ----------------
echo "==> IAM role: AmazonEKSAutoClusterRole (create or reuse)"
if aws iam get-role --role-name AmazonEKSAutoClusterRole --region "$REGION" >/dev/null 2>&1; then
  CLUSTER_ROLE_ARN=$(aws iam get-role --role-name AmazonEKSAutoClusterRole --query 'Role.Arn' --output text --region "$REGION")
  echo "Existing cluster role ARN: $CLUSTER_ROLE_ARN"
else
  cat > /tmp/trust-policy.json <<'EOF'
{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]
}
EOF
  CLUSTER_ROLE_ARN=$(aws iam create-role --role-name AmazonEKSAutoClusterRole --assume-role-policy-document file:///tmp/trust-policy.json --query 'Role.Arn' --output text --region "$REGION")
  for p in AmazonEKSClusterPolicy AmazonEKSComputePolicy AmazonEKSBlockStoragePolicy AmazonEKSLoadBalancingPolicy AmazonEKSNetworkingPolicy; do
    aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn "arn:aws:iam::aws:policy/$p" --region "$REGION"
  done
  echo "Created cluster role ARN: $CLUSTER_ROLE_ARN"
fi

echo "==> IAM role: AmazonEKSAutoNodeRole (create or reuse)"
if aws iam get-role --role-name AmazonEKSAutoNodeRole --region "$REGION" >/dev/null 2>&1; then
  NODE_ROLE_ARN=$(aws iam get-role --role-name AmazonEKSAutoNodeRole --query 'Role.Arn' --output text --region "$REGION")
  echo "Existing node role ARN: $NODE_ROLE_ARN"
else
  cat > /tmp/node-trust-policy.json <<'EOF'
{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
}
EOF
  NODE_ROLE_ARN=$(aws iam create-role --role-name AmazonEKSAutoNodeRole --assume-role-policy-document file:///tmp/node-trust-policy.json --query 'Role.Arn' --output text --region "$REGION")
  aws iam attach-role-policy --role-name AmazonEKSAutoNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy --region "$REGION"
  aws iam attach-role-policy --role-name AmazonEKSAutoNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly --region "$REGION"
  echo "Created node role ARN: $NODE_ROLE_ARN"
fi

# ---------------- Build JSON payload for create-cluster ----------------
cat > /tmp/eks_auto_cluster.json <<EOF
{
  "name": "$CLUSTER_NAME",
  "roleArn": "$CLUSTER_ROLE_ARN",
  "resourcesVpcConfig": {
    "subnetIds": ["$SUBNET1", "$SUBNET2"],
    "endpointPublicAccess": true,
    "endpointPrivateAccess": false
  },
  "computeConfig": {
    "enabled": true,
    "nodePools": ["general-purpose", "system"],
    "nodeRoleArn": "$NODE_ROLE_ARN"
  },
  "kubernetesNetworkConfig": {
    "elasticLoadBalancing": {"enabled": true}
  },
  "storageConfig": {
    "blockStorage": {"enabled": true}
  },
  "accessConfig": {
    "authenticationMode": "API"
  }
}
EOF
echo "==> Creating EKS Auto Mode cluster via --cli-input-json ..."
aws eks create-cluster \
  --cli-input-json file:///tmp/eks_auto_cluster.json \
  --region "$REGION" \
  --output json

CLUSTER_CREATED=true

echo "==> Waiting for cluster to become ACTIVE (this takes ~10–15 minutes)..."
aws eks wait cluster-active \
  --name "$CLUSTER_NAME" \
  --region "$REGION"

echo "Cluster is ACTIVE."

echo "==> Deleting EKS cluster..."
aws eks delete-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION"

echo "==> Waiting for cluster to be fully deleted..."
aws eks wait cluster-deleted \
  --name "$CLUSTER_NAME" \
  --region "$REGION"

echo "Cluster successfully deleted."


VPC_ID=vpc-024f53132bcbebbbb; \
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query "Subnets[0:2].SubnetId" --output text); \
SG=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID --query "SecurityGroups[0].GroupId" --output text); \
ALB_ARN=$(aws elbv2 create-load-balancer --name perm-test-$(date +%s) --type application --scheme internet-facing --subnets $SUBNETS --security-groups $SG --query 'LoadBalancers[0].LoadBalancerArn' --output text) && \
WAF_ARN=$(aws wafv2 create-web-acl --name perm-test-waf-$(date +%s) --scope REGIONAL --default-action Allow={} --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=permTest --query 'Summary.ARN' --output text) && \
aws wafv2 associate-web-acl --web-acl-arn "$WAF_ARN" --resource-arn "$ALB_ARN" && \
aws wafv2 disassociate-web-acl --resource-arn "$ALB_ARN" && \
aws wafv2 delete-web-acl --name $(basename $WAF_ARN) --scope REGIONAL --id $(echo $WAF_ARN | awk -F/ '{print $NF}') && \
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" && \
echo "ALB + WAF SUCCESS" || echo "FAILED (permission or config issue)"

