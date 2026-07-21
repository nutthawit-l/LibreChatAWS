#!/usr/bin/env bash
# Create IAM user + access key for Unpod S3 media bucket, write into unpod/.env
set -euo pipefail

BUCKET_NAME="${BUCKET_NAME:-unpod-media-core-cluster}"
REGION="${REGION:-us-east-1}"
IAM_USER="${IAM_USER:-unpod-s3-poc}"
POLICY_NAME="${POLICY_NAME:-UnpodS3MediaPoC}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/unpod/.env}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "Account: $ACCOUNT_ID | User: $IAM_USER | Bucket: $BUCKET_NAME"

POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}"
    },
    {
      "Sid": "ObjectRW",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
EOF
)

aws iam create-user --user-name "$IAM_USER" 2>/dev/null || echo "IAM user exists: $IAM_USER"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "$POLICY_DOC" \
    --description "PoC access to Unpod media S3 bucket" >/dev/null
  echo "Created policy $POLICY_ARN"
else
  echo "Policy exists: $POLICY_ARN"
fi

aws iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$POLICY_ARN" 2>/dev/null || true

# Delete old access keys (PoC: keep at most one)
for KEY in $(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  echo "Deleting old access key: $KEY"
  aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$KEY"
done

CREDS_JSON="$(aws iam create-access-key --user-name "$IAM_USER" --output json)"
ACCESS_KEY="$(echo "$CREDS_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
SECRET_KEY="$(echo "$CREDS_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE" >&2
  exit 1
fi

python3 - "$ENV_FILE" "$ACCESS_KEY" "$SECRET_KEY" "$BUCKET_NAME" "$REGION" <<'PY'
import pathlib, sys
path, ak, sk, bucket, region = sys.argv[1:6]
text = pathlib.Path(path).read_text()
replacements = {
    "AWS_ACCESS_KEY_ID": ak,
    "AWS_SECRET_ACCESS_KEY": sk,
    "AWS_STORAGE_BUCKET_NAME": bucket,
    "AWS_S3_REGION_NAME": region,
}
out = []
for line in text.splitlines():
    if not line or line.lstrip().startswith("#") or "=" not in line:
        out.append(line)
        continue
    key, _, _ = line.partition("=")
    if key in replacements:
        out.append(f"{key}={replacements[key]}")
    else:
        out.append(line)
pathlib.Path(path).write_text("\n".join(out) + "\n")
print(f"Updated {path}")
PY

echo ""
echo "Done."
echo "  IAM user: $IAM_USER"
echo "  AWS_ACCESS_KEY_ID=$ACCESS_KEY"
echo "  AWS_SECRET_ACCESS_KEY=(written to $ENV_FILE)"
echo "  Bucket: s3://$BUCKET_NAME"
