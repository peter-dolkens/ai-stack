FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir prometheus-client docker

COPY exporter.py .

CMD ["python", "exporter.py"]
