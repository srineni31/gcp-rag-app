#!/bin/bash
set -e

export PROJECT_ID="supple-nature-478602-r0"
export REGION="us-central1"
export PDF_BUCKET="${PROJECT_ID}-rag-pdfs"
export SA_EMAIL="rag-app-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "--- REGENERATING CODE WITH LANGCHAIN FIXES ---"

# 1. Ingest Code (Fixed Imports & Requirements)
mkdir -p ~/rag-deploy/ingest
cat > ~/rag-deploy/ingest/requirements.txt <<INNEREOF
functions-framework==3.*
google-cloud-storage
google-cloud-firestore
langchain==0.2.0
langchain-community==0.2.0
langchain-google-vertexai
langchain-text-splitters
pypdf
INNEREOF

cat > ~/rag-deploy/ingest/main.py <<INNEREOF
import os
import functions_framework
from google.cloud import storage
from google.cloud import firestore
from langchain_google_vertexai import VertexAIEmbeddings
# FIX: New Import Path
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.document_loaders import PyPDFLoader
import tempfile

PROJECT_ID = os.environ.get("GCP_PROJECT")
COLLECTION = "rag_docs"
EMBEDDING_MODEL = "text-embedding-004"

db = None
storage_client = None
embedding_model = None

def get_db():
    global db
    if not db:
        db = firestore.Client(project=PROJECT_ID)
    return db

def get_embedding_model():
    global embedding_model
    if not embedding_model:
        embedding_model = VertexAIEmbeddings(model_name=EMBEDDING_MODEL)
    return embedding_model

@functions_framework.cloud_event
def process_pdf(cloud_event):
    data = cloud_event.data
    bucket_name = data["bucket"]
    file_name = data["name"]

    if not file_name.lower().endswith(".pdf"):
        return

    print(f"Processing {file_name}")
    
    global storage_client
    if not storage_client:
        storage_client = storage.Client()
    
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(file_name)
    
    with tempfile.NamedTemporaryFile(delete=False, suffix=".pdf") as temp_pdf:
        blob.download_to_filename(temp_pdf.name)
        temp_path = temp_pdf.name

    try:
        loader = PyPDFLoader(temp_path)
        documents = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=100)
        chunks = text_splitter.split_documents(documents)
        
        batch = get_db().batch()
        counter = 0
        texts = [c.page_content for c in chunks]
        vectors = get_embedding_model().embed_documents(texts)
        
        for i, chunk in enumerate(chunks):
            doc_ref = get_db().collection(COLLECTION).document()
            doc_data = {
                "content": chunk.page_content,
                "source": file_name,
                "embedding": vectors[i]
            }
            batch.set(doc_ref, doc_data)
            counter += 1
            if counter >= 400:
                batch.commit()
                batch = get_db().batch()
                counter = 0
        if counter > 0:
            batch.commit()
        print("Ingestion complete.")
    finally:
        os.remove(temp_path)
INNEREOF

# 2. Deploy Ingestion Function
echo "--- Deploying Ingestion Function (Fixed) ---"
gcloud functions deploy rag-ingest \
  --gen2 \
  --runtime=python311 \
  --region=$REGION \
  --source=~/rag-deploy/ingest \
  --entry-point=process_pdf \
  --trigger-bucket=$PDF_BUCKET \
  --service-account=$SA_EMAIL \
  --memory=2Gi \
  --timeout=600s \
  --project $PROJECT_ID \
  --quiet

echo "DEPLOYMENT OF INGEST FUNCTION COMPLETE"
