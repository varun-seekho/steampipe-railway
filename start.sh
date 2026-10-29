#!/bin/sh
set -e

for v in RA_CERT_B64 RA_KEY_B64 RA_TRUST_ANCHOR_ARN RA_PROFILE_ARN RA_ROLE_ARN AWS_ACCOUNTS \
         GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET PUBLIC_URL JWT_SIGNING_KEY; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "Missing required variable: $v" >&2; exit 1; }
done

ROLE_NAME="${AWS_ROLE_NAME:-SteampipeReadOnly}"
RA_REGION=$(echo "$RA_TRUST_ANCHOR_ARN" | cut -d: -f4)
RA_DIR="$HOME/.roles-anywhere"
SP_CONFIG="$HOME/.steampipe/config/aws.spc"
HELPER="${SIGNING_HELPER:-/usr/local/bin/aws_signing_helper}"
umask 077
mkdir -p "$RA_DIR" "$HOME/.aws" "$HOME/.steampipe/config"

# Certificate + key from Railway variables -> files only this user can read
echo "$RA_CERT_B64" | base64 -d > "$RA_DIR/client.pem"
echo "$RA_KEY_B64"  | base64 -d > "$RA_DIR/client.key"
unset RA_CERT_B64 RA_KEY_B64
# Never fall back to static keys, even if someone sets them
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

echo "Certificate expires: $(openssl x509 -in "$RA_DIR/client.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo unknown)"

HELPER_CMD="$HELPER credential-process --certificate $RA_DIR/client.pem --private-key $RA_DIR/client.key --trust-anchor-arn $RA_TRUST_ANCHOR_ARN --profile-arn $RA_PROFILE_ARN --role-arn $RA_ROLE_ARN --region $RA_REGION"

# Regions: "us-east-1,eu-west-1" -> ["us-east-1", "eu-west-1"]; default all.
if [ -n "${AWS_REGIONS:-}" ]; then
  REGIONS="[$(echo "$AWS_REGIONS" | tr -d ' ' | sed 's/[^,][^,]*/"&"/g; s/,/, /g')]"
else
  REGIONS='["*"]'
fi

# Base profile: short-lived SteampipeHub credentials from Roles Anywhere
cat > "$HOME/.aws/config" <<BASE
[profile steampipe-hub]
credential_process = $HELPER_CMD
region = $RA_REGION

BASE
: > "$HOME/.aws/credentials"

# Aggregator named "aws" sorts first, so unqualified table names query ALL accounts.
cat > "$SP_CONFIG" <<AGG
connection "aws" {
  plugin      = "aws"
  type        = "aggregator"
  connections = ["aws_*"]
}
AGG

# AWS_ACCOUNTS="prod=111111111111,staging=222222222222"
for entry in $(echo "$AWS_ACCOUNTS" | tr ',' ' '); do
  name=$(echo "${entry%%=*}" | tr 'A-Z-' 'a-z_')
  id="${entry#*=}"
  echo "$name" | grep -Eq '^[a-z][a-z0-9_]*$' || { echo "Bad account name: $name" >&2; exit 1; }
  echo "$id" | grep -Eq '^[0-9]{12}$' || { echo "Bad account id for $name: $id" >&2; exit 1; }

  cat >> "$HOME/.aws/config" <<PROFILE
[profile $name]
role_arn = arn:aws:iam::$id:role/$ROLE_NAME
source_profile = steampipe-hub
role_session_name = steampipe-railway

PROFILE

  cat >> "$SP_CONFIG" <<CONN

connection "aws_$name" {
  plugin  = "aws"
  profile = "$name"
  regions = $REGIONS
}
CONN
  echo "Configured account aws_$name ($id)"
done

[ "${DRY_RUN:-}" = "1" ] && { cat "$SP_CONFIG"; echo ---; cat "$HOME/.aws/config"; exit 0; }

# Fail fast with a clear message if the certificate setup is wrong
if ! $HELPER_CMD > /dev/null; then
  echo "Roles Anywhere sign-in failed. Check the certificate, the three RA_* ARNs, and that the cert hasn't expired." >&2
  exit 1
fi
echo "Roles Anywhere OK."

# Database only listens inside the container
steampipe service start --database-listen local

echo "Waiting for Steampipe..."
until steampipe query "select 1" >/dev/null 2>&1; do sleep 2; done
echo "Steampipe ready."

exec python /home/steampipe/server.py
