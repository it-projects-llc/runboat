FROM python:3.13

LABEL maintainer="Stéphane Bidoul"

ADD https://dl.k8s.io/release/stable.txt /tmp/kubectl-version.txt
RUN curl -L \
  "https://dl.k8s.io/release/$(cat /tmp/kubectl-version.txt)/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# KUBECONFIG to be provided by user, unless running in cluster with a service account
# having the necessary permissions.

COPY log-config.yaml /etc/runboat-log-config.yaml
ENV RUNBOAT_LOG_CONFIG=/etc/runboat-log-config.yaml

COPY src /app
ENV PYTHONPATH=/app

EXPOSE 8000

CMD [ "gunicorn", "-w", "1", "--bind", ":8000", "-k", "runboat.uvicorn.RunboatUvicornWorker", "--access-logfile=-", "runboat.app:app"]
