FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir prometheus-client

COPY exporter.py .

CMD ["python", "exporter.py"]
