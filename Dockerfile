FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates procps openssl python3 python3-venv \
 && rm -rf /var/lib/apt/lists/*

# IAM Roles Anywhere credential helper (checksum from AWS docs)
ARG SIGNING_HELPER_VERSION=1.8.5
ARG SIGNING_HELPER_SHA256=beec9ed1c492d93db809890f16713e3556353294b823c2184ad4e891f1b2b54d
RUN curl -fsSL -o /usr/local/bin/aws_signing_helper \
      "https://rolesanywhere.amazonaws.com/releases/${SIGNING_HELPER_VERSION}/X86_64/Linux/Amzn2023/aws_signing_helper" \
 && echo "${SIGNING_HELPER_SHA256}  /usr/local/bin/aws_signing_helper" | sha256sum -c - \
 && chmod 755 /usr/local/bin/aws_signing_helper

# Steampipe CLI
RUN /bin/sh -c "$(curl -fsSL https://steampipe.io/install/steampipe.sh)"

# Steampipe MCP server (stdio). Pin an exact version once your first build works.
RUN npm install -g @turbot/steampipe-mcp

# OAuth front door (FastMCP + Google)
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir "fastmcp==4.1.4"
ENV PATH="/opt/venv/bin:${PATH}"

# Steampipe refuses to run as root
RUN useradd -m -u 9193 steampipe
USER steampipe
WORKDIR /home/steampipe

ENV STEAMPIPE_UPDATE_CHECK=false \
    STEAMPIPE_TELEMETRY=none \
    PYTHONUNBUFFERED=1

# Bake the AWS plugin into the image so boots are fast
RUN steampipe plugin install aws

COPY --chown=steampipe:steampipe start.sh server.py /home/steampipe/
RUN chmod +x /home/steampipe/start.sh

CMD ["/home/steampipe/start.sh"]
