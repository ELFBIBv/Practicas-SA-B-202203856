FROM python:3.11-slim
# Trae los parches de seguridad ya publicados para esta misma versión de
# Debian slim (no cambia de versión mayor, solo actualiza paquetes del SO).
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
RUN adduser --system --group appuser
USER 10001
CMD ["python", "main.py"]
