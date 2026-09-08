FROM python:3.13-slim

LABEL org.opencontainers.image.source="https://github.com/BokEumEom/platform-engineering-lab"

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

USER 10001

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
