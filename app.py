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
