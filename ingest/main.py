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
