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
