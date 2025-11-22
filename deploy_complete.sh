#!/bin/bash
set -e # Stop on error

# --- CONFIGURATION ---
export PROJECT_ID="supple-nature-478602-r0"
export REGION="us-central1"
export PDF_BUCKET="${PROJECT_ID}-rag-pdfs"
export SA_EMAIL="rag-app-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==================================================="
echo "STARTING COMPLETE DEPLOYMENT FOR $PROJECT_ID"
echo "==================================================="

# 1. Enable APIs
echo "[1/9] Enabling APIs..."
gcloud services enable \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  firestore.googleapis.com \
  aiplatform.googleapis.com \
  eventarc.googleapis.com \
  cloudbuild.googleapis.com \
  --project $PROJECT_ID

# 2. Permissions
echo "[2/9] Configuring Permissions..."
gcloud iam service-accounts create rag-app-sa --display-name="RAG Service Account" --project $PROJECT_ID || true
sleep 5 # Wait for propagation

for role in roles/datastore.owner roles/storage.objectViewer roles/aiplatform.user roles/logging.logWriter roles/eventarc.eventReceiver roles/run.invoker; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SA_EMAIL" \
    --role=$role \
    --condition=None > /dev/null
done

# 3. Buckets
echo "[3/9] Creating Bucket: $PDF_BUCKET..."
gsutil mb -l $REGION gs://$PDF_BUCKET/ || true

# 4. GENERATE CODE
echo "[4/9] Generating Application Code..."

# --- INGESTION CODE (Fixed Imports) ---
mkdir -p ~/rag-deploy/ingest
cat > ~/rag-deploy/ingest/requirements.txt <<EOF
functions-framework==3.*
google-cloud-storage
google-cloud-firestore
langchain
langchain-community
langchain-google-vertexai
langchain-text-splitters
pypdf
EOF

cat > ~/rag-deploy/ingest/main.py <<EOF
import os
import functions_framework
from google.cloud import storage
from google.cloud import firestore
from langchain_google_vertexai import VertexAIEmbeddings
# FIX: Updated import path for newer LangChain versions
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
        print(f"Skipping non-pdf: {file_name}")
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
        if os.path.exists(temp_path):
            os.remove(temp_path)
EOF

# --- RETRIEVAL CODE ---
mkdir -p ~/rag-deploy/retrieve
cat > ~/rag-deploy/retrieve/requirements.txt <<EOF
functions-framework==3.*
google-cloud-firestore
langchain
langchain-community
langchain-google-vertexai
google-cloud-aiplatform
flask
EOF

cat > ~/rag-deploy/retrieve/main.py <<EOF
import os
import functions_framework
from google.cloud import firestore
from google.cloud.firestore_v1.vector import Vector
from google.cloud.firestore_v1.base_vector_query import DistanceMeasure
from langchain_google_vertexai import VertexAIEmbeddings, ChatVertexAI
from langchain.prompts import PromptTemplate
from flask import jsonify

PROJECT_ID = os.environ.get("GCP_PROJECT")
COLLECTION = "rag_docs"
EMBEDDING_MODEL = "text-embedding-004"
GEN_MODEL = "gemini-1.5-flash"

db = None
embedding_model = None
llm = None

def get_services():
    global db, embedding_model, llm
    if not db:
        db = firestore.Client(project=PROJECT_ID)
    if not embedding_model:
        embedding_model = VertexAIEmbeddings(model_name=EMBEDDING_MODEL)
    if not llm:
        llm = ChatVertexAI(model_name=GEN_MODEL, temperature=0.2)
    return db, embedding_model, llm

@functions_framework.http
def retrieve_and_generate(request):
    # CORS Support
    if request.method == 'OPTIONS':
        headers = {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'POST',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Max-Age': '3600'
        }
        return ('', 204, headers)

    headers = {'Access-Control-Allow-Origin': '*'}
    
    request_json = request.get_json(silent=True)
    query_text = request_json.get("query")
    
    if not query_text:
        return jsonify({"error": "No query provided"}), 400, headers

    db, embed_model, gemini = get_services()
    query_embedding = embed_model.embed_query(query_text)

    collection = db.collection(COLLECTION)
    vector_query = collection.find_nearest(
        vector_field="embedding",
        query_vector=Vector(query_embedding),
        distance_measure=DistanceMeasure.COSINE,
        limit=5
    )
    
    docs = vector_query.get()
    context_text = "\n\n".join([d.get("content") for d in docs])

    prompt_template = """You are a helpful assistant. Use the context below to answer the question.
    Context: {context}
    Question: {question}
    Answer:"""
    
    prompt = PromptTemplate.from_template(prompt_template)
    chain = prompt | gemini
    response = chain.invoke({"context": context_text, "question": query_text})
    
    return jsonify({"answer": response.content, "context_used": context_text}), 200, headers
EOF

# --- FRONTEND CODE ---
mkdir -p ~/rag-deploy/frontend
cat > ~/rag-deploy/frontend/Dockerfile <<EOF
FROM python:3.9-slim
WORKDIR /app
RUN pip install streamlit requests
COPY app.py .
CMD streamlit run app.py --server.port 8080 --server.address 0.0.0.0
EOF

cat > ~/rag-deploy/frontend/app.py <<EOF
import streamlit as st
import requests
import os

API_URL = os.environ.get("API_URL")

st.set_page_config(page_title="RAG Chat", layout="wide")
st.title("📄 Document Chat (RAG)")

if "messages" not in st.session_state:
    st.session_state.messages = []

for message in st.session_state.messages:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])

if prompt := st.chat_input("Ask about your documents..."):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        if not API_URL:
            st.error("API_URL not configured.")
            st.stop()
            
        with st.spinner("Thinking..."):
            try:
                response = requests.post(API_URL, json={"query": prompt})
                if response.status_code == 200:
                    answer = response.json().get("answer", "No answer found.")
                    st.markdown(answer)
                    st.session_state.messages.append({"role": "assistant", "content": answer})
                else:
                    st.error(f"Error: {response.status_code}")
            except Exception as e:
                st.error(f"Connection Error: {e}")
EOF

# 5. DEPLOY FUNCTIONS
echo "[5/9] Deploying Ingest Function (2Gi, 540s)..."
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

echo "[6/9] Deploying Retrieval Function (2Gi, 540s)..."
gcloud functions deploy rag-retrieve \
  --gen2 \
  --runtime=python311 \
  --region=$REGION \
  --source=./retrieve \
  --entry-point=retrieve_and_generate \
  --trigger-http \
  --allow-unauthenticated \
  --memory=2Gi \
  --timeout=540s \
  --service-account=$SA_EMAIL \
  --project $PROJECT_ID \
  --quiet

# 6. CREATE INDEX
echo "[7/9] Ensuring Vector Index Exists..."
gcloud firestore indexes composite create \
  --collection-group=rag_docs \
  --query-scope=COLLECTION \
  --field-config field-path=embedding,vector-config='{"dimension":768,"flat":{}}' \
  --project=$PROJECT_ID || echo "Index likely exists, continuing..."

# 7. DEPLOY FRONTEND
echo "[8/9] Building Frontend Image..."
RETRIEVE_URL=$(gcloud functions describe rag-retrieve --gen2 --region=$REGION --project=$PROJECT_ID --format="value(serviceConfig.uri)")

gcloud builds submit --tag gcr.io/$PROJECT_ID/rag-frontend frontend/ --project $PROJECT_ID --quiet

echo "[9/9] Deploying Frontend Service..."
gcloud run deploy rag-frontend \
  --image gcr.io/$PROJECT_ID/rag-frontend \
  --platform managed \
  --region $REGION \
  --allow-unauthenticated \
  --set-env-vars API_URL=$RETRIEVE_URL \
  --project $PROJECT_ID \
  --quiet

echo "==================================================="
echo "✅ DEPLOYMENT COMPLETE!"
echo "==================================================="
