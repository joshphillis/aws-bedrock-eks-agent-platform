FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app

# Create non-root user
RUN addgroup --system app && adduser --system --ingroup app app

# Install dependencies before copying source (layer cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

RUN chown -R app:app /app

USER app

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
