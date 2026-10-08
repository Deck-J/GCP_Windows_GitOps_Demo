#!/usr/bin/env bash
# Prepare the restricted Visual Studio media bucket, builder identity, and optional product-key secret.
# Product keys are entered interactively and stored only in Google Secret Manager.
set -Eeuo pipefail

PROJECT_ID="${1:?project id is required}"
BUCKET_NAME="${2:?bucket name is required}"
BUILD_SERVICE_ACCOUNT="${3:?Cloud Build service account email is required}"
BUILDER_SA_NAME="${4:-windows-image-builder}"
SECRET_NAME="${5:-vs2022-enterprise-product-key}"
VS_EDITION="${6:-community}"
VS_EDITION="$(printf '%s' "$VS_EDITION" | tr '[:upper:]' '[:lower:]')"
[[ "$VS_EDITION" =~ ^(community|professional|enterprise)$ ]] || { echo "Edition must be community, professional, or enterprise"; exit 1; }
BUILDER_SA="${BUILDER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud services enable compute.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com storage.googleapis.com \
  --project="$PROJECT_ID"

# Offline media is read by a separate builder identity; Cloud Build may impersonate
# that identity but does not receive broad access to the media bucket itself.
if ! gcloud iam service-accounts describe "$BUILDER_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$BUILDER_SA_NAME" \
    --project="$PROJECT_ID" --display-name="Temporary Windows image builder"
fi

if ! gcloud storage buckets describe "gs://$BUCKET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$BUCKET_NAME" \
    --project="$PROJECT_ID" --location=us-central1 --uniform-bucket-level-access
fi

gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
  --member="serviceAccount:$BUILDER_SA" --role=roles/storage.objectViewer

if [[ "$VS_EDITION" != "community" ]]; then
  if ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets create "$SECRET_NAME" --project="$PROJECT_ID" --replication-policy=automatic
  fi

  read -r -s -p "Visual Studio product key: " VS_PRODUCT_KEY
  echo
  NORMALIZED_KEY="$(printf '%s' "$VS_PRODUCT_KEY" | tr -d '-' | tr -d '[:space:]')"
  unset VS_PRODUCT_KEY
  [[ "$NORMALIZED_KEY" =~ ^[A-Za-z0-9]{25}$ ]] || { echo "Product key must contain 25 alphanumeric characters"; exit 1; }
  printf '%s' "$NORMALIZED_KEY" | gcloud secrets versions add "$SECRET_NAME" \
    --project="$PROJECT_ID" --data-file=-
  unset NORMALIZED_KEY

  gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:$BUILDER_SA" \
    --role=roles/secretmanager.secretAccessor
fi

# Scope Cloud Build's impersonation grant to this builder account. The edition-
# specific secret grant above is omitted for Community, which needs no product key.
gcloud iam service-accounts add-iam-policy-binding "$BUILDER_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$BUILD_SERVICE_ACCOUNT" \
  --role=roles/iam.serviceAccountUser

echo "BUILDER_SERVICE_ACCOUNT=$BUILDER_SA"
if [[ "$VS_EDITION" == "community" ]]; then
  echo "VS_PRODUCT_KEY_SECRET=unused"
else
  echo "VS_PRODUCT_KEY_SECRET=$SECRET_NAME"
fi
echo "VS_MEDIA_URI=gs://$BUCKET_NAME/vs2022-${VS_EDITION}-layout.iso"
