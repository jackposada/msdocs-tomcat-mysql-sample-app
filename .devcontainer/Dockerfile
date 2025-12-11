FROM mcr.microsoft.com/devcontainers/java:1-17-bullseye
RUN apt-get update \
  && apt-get install -y --no-install-recommends default-mysql-client \
  && rm -rf /var/lib/apt/lists/*