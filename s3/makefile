REGION ?= us-east-1
BUCKET_NAME ?= unpod-media-core-cluster
# Optional override via .env (BUCKET_NAME=..., REGION=...)
-include .env
export

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "S3 bucket for Unpod media (PoC)"
	@echo ""
	@echo "Targets:"
	@echo "  check     Verify AWS identity"
	@echo "  create    Create encrypted private bucket + CORS"
	@echo "  status    Show bucket info"
	@echo "  destroy   Empty and delete bucket (destructive)"
	@echo "  conninfo  Print values for unpod/.env"
	@echo ""
	@echo "Variables:"
	@echo "  BUCKET_NAME=$(BUCKET_NAME)"
	@echo "  REGION=$(REGION)"
	@echo ""
	@echo "Usage:"
	@echo "  cp .env.example .env   # optional"
	@echo "  make create"

.PHONY: check
check:
	@aws sts get-caller-identity | cat
	@echo "Bucket: $(BUCKET_NAME) | Region: $(REGION)"

.PHONY: create
create: check
	@if aws s3api head-bucket --bucket "$(BUCKET_NAME)" 2>/dev/null; then \
		echo "Bucket already exists: s3://$(BUCKET_NAME)"; \
	else \
		echo "Creating s3://$(BUCKET_NAME) in $(REGION)..."; \
		if [ "$(REGION)" = "us-east-1" ]; then \
			aws s3api create-bucket --bucket "$(BUCKET_NAME)" --region "$(REGION)"; \
		else \
			aws s3api create-bucket --bucket "$(BUCKET_NAME)" --region "$(REGION)" \
				--create-bucket-configuration LocationConstraint="$(REGION)"; \
		fi; \
	fi
	@echo "Block public access..."
	aws s3api put-public-access-block \
		--bucket "$(BUCKET_NAME)" \
		--public-access-block-configuration \
			BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
	@echo "Default encryption (AES256)..."
	aws s3api put-bucket-encryption \
		--bucket "$(BUCKET_NAME)" \
		--server-side-encryption-configuration \
			'{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
	@echo "Ownership: BucketOwnerEnforced..."
	aws s3api put-bucket-ownership-controls \
		--bucket "$(BUCKET_NAME)" \
		--ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
	@echo "CORS (app + API hosts)..."
	aws s3api put-bucket-cors \
		--bucket "$(BUCKET_NAME)" \
		--cors-configuration file://cors.json
	@echo "Tags..."
	aws s3api put-bucket-tagging \
		--bucket "$(BUCKET_NAME)" \
		--tagging 'TagSet=[{Key=Project,Value=unpod},{Key=Environment,Value=poc},{Key=ManagedBy,Value=makefile}]'
	@echo ""
	@echo "Created s3://$(BUCKET_NAME)"
	@$(MAKE) --no-print-directory conninfo

.PHONY: status
status: check
	@aws s3api head-bucket --bucket "$(BUCKET_NAME)" 2>/dev/null \
		&& echo "Exists: s3://$(BUCKET_NAME)" \
		|| (echo "Missing: s3://$(BUCKET_NAME)" && exit 1)
	@echo ""
	@aws s3api get-bucket-location --bucket "$(BUCKET_NAME)" --output text | \
		awk '{print "Location:", ($$0=="None"||$$0==""?"us-east-1":$$0)}'
	@aws s3api get-public-access-block --bucket "$(BUCKET_NAME)" 2>/dev/null || true
	@aws s3api get-bucket-encryption --bucket "$(BUCKET_NAME)" 2>/dev/null || true
	@aws s3 ls "s3://$(BUCKET_NAME)" --summarize --human-readable 2>/dev/null | tail -5 || true

.PHONY: destroy
destroy: check
	@echo "WARNING: This empties and deletes s3://$(BUCKET_NAME)"
	@printf "Type the bucket name to confirm: "
	@read confirm && [ "$$confirm" = "$(BUCKET_NAME)" ] || (echo "Aborted" && exit 1)
	aws s3 rm "s3://$(BUCKET_NAME)" --recursive || true
	aws s3api delete-bucket --bucket "$(BUCKET_NAME)" --region "$(REGION)"
	@echo "Deleted s3://$(BUCKET_NAME)"

.PHONY: conninfo
conninfo:
	@echo ""
	@echo "Add to unpod/.env:"
	@echo "  AWS_STORAGE_BUCKET_NAME=$(BUCKET_NAME)"
	@echo "  AWS_S3_REGION_NAME=$(REGION)"
	@echo "  AWS_ACCESS_KEY_ID=<iam-user-or-role-key>"
	@echo "  AWS_SECRET_ACCESS_KEY=<iam-secret>"
	@echo ""
	@echo "Bucket URL: https://$(BUCKET_NAME).s3.$(REGION).amazonaws.com"
	@echo "PoC tip: create an IAM user with AmazonS3FullAccess on this bucket only,"
	@echo "         or use IRSA / Pod Identity on the Unpod service account later."
