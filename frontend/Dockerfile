FROM python:3.9-slim
WORKDIR /app
RUN pip install streamlit requests
COPY app.py .
CMD streamlit run app.py --server.port 8080 --server.address 0.0.0.0
