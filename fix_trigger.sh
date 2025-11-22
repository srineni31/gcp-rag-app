#!/bin/bash
set -e

export PROJECT_ID="supple-nature-478602-r0"
export REGION="us-central1"
export PDF_BUCKET="${PROJECT_ID}-rag-pdfs"
export SA_EMAIL="rag-app-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==================================================="
echo "FIXING PERMISSIONS AND TRIGGER FOR $PROJECT_ID"
echo "==================================================="

# 0. Force Global Config (Fixes 'none configured' error)
gcloud config set project $PROJECT_ID

# 1. Find the Google Storage Service Agent
echo "[1/5] Identifying Google Storage Service Agent..."
STORAGE_SERVICE_AGENT=$(gcloud storage service-agent --project=$PROJECT_ID)
echo "Found Agent: $STORAGE_SERVICE_AGENT"

# 2. Grant Pub/Sub Publisher Role
echo "[2/5] Granting Pub/Sub Publisher Role..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$STORAGE_SERVICE_AGENT" \
    --role="roles/pubsub.publisher" \
    --condition=None > /dev/null

# 3. Clean up the Bucket (Explicitly using Project ID)
echo "[3/5] Resetting Bucket..."
# Try to delete existing bucket (ignore errors if it doesn't exist)
gsutil rm -r gs://$PDF_BUCKET/ || true
gsutil rb gs://$PDF_BUCKET/ || true
sleep 5

# Create bucket explicitly with Project ID flag (-p)
echo "Creating bucket: gs://$PDF_BUCKET"
gsutil mb -p $PROJECT_ID -l $REGION gs://$PDF_BUCKET/

# 4. Delete the failed function
echo "[4/5] Cleaning up failed function state..."
gcloud functions delete rag-ingest --gen2 --region=$REGION --project=$PROJECT_ID --quiet || true

# 5. Deploy Ingestion Function Again
echo "[5/5] Redeploying Ingestion Function..."
cd ~/rag-deploy
gcloud functions deploy rag-ingest \
  --gen2 \
  --runtime=python311 \
  --region=$REGION \
  --source=./ingest \
  --entry-point=process_pdf \
  --trigger-bucket=$PDF_BUCKET \
  --service-account=$SA_EMAIL \
  --memory=2Gi \
  --timeout=540s \
  --project $PROJECT_ID \
  --quiet

echo "==================================================="
echo "FIX COMPLETE. INGESTION FUNCTION DEPLOYED."
echo "==================================================="
