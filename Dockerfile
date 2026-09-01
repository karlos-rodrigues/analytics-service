# syntax=docker/dockerfile:1
#
# analytics-service (Python) — worker SQS -> DynamoDB, com um /health em Flask.
# Build multi-stage; estágio 2 recebe só o virtualenv.

# ---------- estágio 1: dependências ----------
FROM python:3.11-slim AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app
COPY requirements.txt constraints.txt requirements-container.txt ./

# Duas etapas propositalmente separadas:
#  1) o requirements.txt da FIAP, com o Werkzeug travado em 2.x (ver constraints.txt);
#  2) o delta do contêiner — hoje só o boto3 (ver requirements-container.txt).
RUN pip install -r requirements.txt -c constraints.txt \
 && pip install -r requirements-container.txt

# ---------- estágio 2: runtime ----------
FROM python:3.11-slim AS runtime

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN useradd --create-home --uid 10001 app

COPY --from=build /opt/venv /opt/venv

WORKDIR /app
COPY --chown=app:app app.py ./

USER app
EXPOSE 8005

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=5 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8005/health', timeout=2).status == 200 else 1)"]

# --workers 1 é obrigatório aqui, não é economia de recurso.
# O app.py chama start_worker() no escopo do módulo, ou seja, no import. Cada worker
# do Gunicorn abriria um consumidor independente da MESMA fila SQS. Com 1 worker,
# 1 pod = 1 consumidor, e a contagem de réplicas do HPA/KEDA passa a ser
# proporcional à vazão real de mensagens.
CMD ["gunicorn", "--bind", "0.0.0.0:8005", \
     "--workers", "1", "--threads", "4", \
     "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]
