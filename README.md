# GCP RAG Chatbot Proof‑of‑Concept

This repository contains a minimal Retrieval‑Augmented Generation
(RAG) chatbot built on top of Google Cloud Platform.  It showcases
how to use **LangChain**, **Vertex AI Embeddings**, **Vertex AI Vector
Search** (formerly Matching Engine) and a **Gemini** chat model to
answer questions about your own documents.  The proof of concept is
designed for personal or volunteer projects that wish to stay within
free tier allowances.

## Project Structure

- `setup_rag.py` – Script to create a Matching Engine index, deploy it
  to an endpoint and ingest your documents.  Run this once after
  configuring your environment and placing your source documents in the
  `data/` folder.  It supports plain‑text, PDF and Word documents
  (`.txt`, `.pdf`, `.docx`).
- `app.py` – Streamlit application that exposes a simple chat
  interface.  It connects to the deployed index and uses a Vertex
  Gemini model to generate answers based on retrieved documents.
- `requirements.txt` – Python dependencies required for both the
  setup script and the Streamlit app.
- `data/` – Place your source documents here.  Supported formats
  include `.txt`, `.pdf` and `.docx`.  Files are loaded
  recursively and split into chunks before being embedded and
  indexed.

## Prerequisites

1. A Google Cloud project with the **Vertex AI API** enabled.
2. A **Google Cloud Storage** bucket.  This is used as a staging
   location for Matching Engine operations and does not need to be
   publicly accessible.
3. Python 3.10 or later.

## Setup

1. Clone this repository or copy the files into your own working
   directory.
2. Install the dependencies:

   ```bash
   pip install -r requirements.txt
   ```

3. Export the required environment variables.  Replace the placeholders
   with your own values:

   ```bash
   export PROJECT_ID="my‑gcp‑project"
   export REGION="us‑central1"
   export BUCKET_NAME="my‑rag‑staging"
   export INDEX_DISPLAY_NAME="rag‑index"
   export DEPLOYED_INDEX_ID="rag‑deployed"
   ```

4. Add your documents to the `data/` directory.  Supported formats
   include `.txt`, `.pdf` and `.docx`.  Each file can be as long as you
   like; the setup script will split the content into overlapping
   chunks for embedding.

5. Run the setup script to create and populate the index:

   ```bash
   python setup_rag.py
   ```

   **Important:** Creating and deploying a Matching Engine index can
   take several minutes.  Although Vertex AI offers generous free
   allowances, indexing and embedding incur small costs after you
   exceed the free tier.  Keep an eye on your billing dashboard if
   you plan to index large amounts of data.

## Running the Chatbot

After the setup script completes you can launch the Streamlit app:

```bash
export INDEX_ID="<your index resource name>"
export ENDPOINT_ID="<your endpoint resource name>"
streamlit run app.py
```

When the page loads you can type questions about the content of your
documents.  The app performs a similarity search using Vertex AI
Vector Search, feeds the top results into a Gemini model and displays
the answer along with the source snippets.

### Deployment to Cloud Run

For a zero‑ops deployment on GCP you can build a container with
Streamlit and deploy it to Cloud Run.  The following minimal
`Dockerfile` illustrates how:

```Dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt
ENV PORT=8080
CMD ["streamlit", "run", "app.py", "--server.port=8080", "--server.enableCORS=false"]
```

Build and deploy using the gcloud CLI:

```bash
gcloud builds submit --tag gcr.io/$PROJECT_ID/rag-chatbot
gcloud run deploy rag-chatbot \
  --image gcr.io/$PROJECT_ID/rag-chatbot \
  --platform managed --region $REGION --allow-unauthenticated \
  --update-env-vars "PROJECT_ID=$PROJECT_ID,REGION=$REGION,BUCKET_NAME=$BUCKET_NAME,INDEX_ID=<your index ID>,ENDPOINT_ID=<your endpoint ID>"
```

Cloud Run’s free tier should cover small demos.  Note that Vertex AI
calls may incur charges once you exceed the monthly free allowance.

## Limitations & Notes

- Vertex AI Vector Search (Matching Engine) is a managed service and
  thus not entirely free.  It offers a generous per‑month free tier
  for indexing and query operations.  Avoid re‑indexing large
  datasets frequently.
- The provided embedding model (`text-embedding-004`) and chat model
  (`gemini-pro`) also come with limited free quotas.  Consider using
  smaller models or caching results if cost becomes an issue.

This proof of concept supports ingestion of plain‑text, PDF and Word
documents out of the box.  For PDF ingestion we rely on the
`PyPDFLoader` from LangChain, which uses the lightweight `pypdf`
library.  For Word documents we use the `Docx2txtLoader`; it can
only read `.docx` files.  If you need to ingest other formats or
legacy `.doc` files, consider extending `setup_rag.py` with
additional loaders such as `UnstructuredWordDocumentLoader`【956208899455155†L396-L408】 and
`UnstructuredPDFLoader`【893739761739934†L66-L90】 from LangChain.

## References

This project was inspired by the official LangChain and Vertex AI
examples on integrating vector search and Gemini models:

- [LangChain documentation on Google Vertex AI Vector Search](https://docs.langchain.com/oss/python/integrations/vectorstores/google_vertex_ai_vector_search)【727109338423774†L190-L237】
- [Zilliz guide on building a RAG chatbot with Vertex AI components](https://zilliz.com/tutorials/rag/langchain-and-langchain-vector-store-and-google-vertex-ai-gemini-2.0-pro-and-google-vertex-ai-text-embedding-004)【93536901870296†L186-L209】
# gcp-rag-app
GCP RAG Deployment app
