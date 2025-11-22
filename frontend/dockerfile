FROM python:3.9-slim
WORKDIR /app
COPY . .
RUN pip install streamlit requests
CMD streamlit run app.py --server.port 8080 --server.address 0.0.0.0
