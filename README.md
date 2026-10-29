# Steampipe MCP on Railway, behind Google sign-in

Teammates add one URL to Claude or ChatGPT, sign in with Google, and can query your AWS account in plain English. Only allowlisted, verified Google accounts get in, and every query is logged with the user's email.

```
Claude / ChatGPT ──HTTPS + OAuth──▶ FastMCP (Google sign-in, allowlist, audit log)
                                        │ stdio
                                        ▼
                                  steampipe-mcp ──▶ Steampipe (Postgres) ──▶ AWS APIs
```

## 1. AWS: certificate-based access (no IAM users, no access keys)

The server proves who it is with a **certificate** (IAM Roles Anywhere) and gets 1-hour AWS credentials, renewed automatically. There is no IAM user and no access key anywhere.

```
Railway server (client certificate)
   └─ Roles Anywhere ─▶ SteampipeHub role (home account; can only assume SteampipeReadOnly)
                           └─ sts:AssumeRole ─▶ SteampipeReadOnly in each account (SecurityAudit + deny secrets & data)
```

Use your Prism login (console, or `ck-prism login` for the CLI) with an admin-level permission set for these steps.

**1a. Make the certificates (on your laptop)**

```
sh make-certs.sh
```

This creates `steampipe-pki/` with a private CA and a 90-day client certificate, and prints `RA_CERT_B64` and `RA_KEY_B64` for Railway. **Move `steampipe-pki/ca.key` to a password manager or vault.** Anyone with it can mint certificates. It is needed again only to rotate.

**1b. Home account: deploy `steampipe-hub.yaml`**

Pick a region (Roles Anywhere is regional; any region works for querying all regions). Use the CLI so the certificate's line breaks are kept:

```
aws cloudformation deploy \
  --profile <your-prism-profile> --region <region> \
  --stack-name steampipe-hub \
  --template-file steampipe-hub.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides CaCertificatePem="$(cat steampipe-pki/ca.pem)"

aws cloudformation describe-stacks --profile <your-prism-profile> --region <region> \
  --stack-name steampipe-hub --query "Stacks[0].Outputs" --output table
```

Note the three outputs: `TrustAnchorArn`, `ProfileArn`, `HubRoleArn`.

**1c. Every account (including home): deploy `steampipe-readonly-role.yaml`**

Pass `HubRoleArn` from 1b. Deploy the hub stack first, because IAM rejects a trust policy that points at a role that doesn't exist yet.

- With AWS Organizations: CloudFormation → StackSets, target your accounts/OUs. StackSets don't deploy into the management account itself; if you want to query that account too, create a normal stack there.
- Otherwise: a normal stack in each account.
- Tick the acknowledgement for named IAM resources.

If some Steampipe tables return AccessDenied, add only the specific `Describe*/List*/Get*` actions they need to the template and update the stack(s).

## 2. Railway: create the service and get its URL

1. Push this folder to a private GitHub repo.
2. Railway → New Project → Deploy from GitHub repo (it builds the Dockerfile).
3. Settings → Networking → Generate Domain. Note it, e.g. `https://steampipe-xyz.up.railway.app`.
4. Give the service at least 2 GB RAM (Steampipe runs an embedded Postgres).

The first deploy will fail until the variables below are set. That's expected.

## 3. Google Cloud: OAuth client

1. console.cloud.google.com → create or pick a project.
2. **APIs & Services → OAuth consent screen**
   - If your team uses Google Workspace: choose **Internal**. Only accounts in your Workspace can sign in at all.
   - Otherwise choose **External**, add only the `openid` and `email` scopes, then **Publish** the app. (In "Testing" status Google expires sign-ins after 7 days. With only these basic scopes, publishing doesn't need Google verification.)
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**
   - Application type: **Web application**
   - Authorized redirect URI: `https://<your-railway-domain>/auth/callback`
4. Copy the Client ID and Client Secret.

## 4. Railway variables

| Name | Value |
|---|---|
| `RA_CERT_B64` | printed by `make-certs.sh` |
| `RA_KEY_B64` | printed by `make-certs.sh` |
| `RA_TRUST_ANCHOR_ARN` | `TrustAnchorArn` output from 1b |
| `RA_PROFILE_ARN` | `ProfileArn` output from 1b |
| `RA_ROLE_ARN` | `HubRoleArn` output from 1b |
| `AWS_ACCOUNTS` | `name=accountid` pairs, e.g. `prod=111111111111,staging=222222222222,dev=333333333333` |
| `AWS_REGIONS` | the regions you use, e.g. `us-east-1,eu-west-1` (leave unset for all regions, much slower) |
| `GOOGLE_CLIENT_ID` | from step 3 |
| `GOOGLE_CLIENT_SECRET` | from step 3 |
| `PUBLIC_URL` | `https://<your-railway-domain>` (no trailing slash) |
| `JWT_SIGNING_KEY` | output of `openssl rand -hex 32` |
| `ALLOWED_EMAIL_DOMAINS` | e.g. `yourcompany.com` (comma-separated) |
| `ALLOWED_EMAILS` | optional, specific addresses, e.g. `contractor@gmail.com` |

At least one of `ALLOWED_EMAIL_DOMAINS` / `ALLOWED_EMAILS` is required; the server refuses to start without it. Never put `gmail.com` in the domain list.

Redeploy. The logs should show the certificate expiry date, `Roles Anywhere OK.`, `Configured account aws_<name>` for each account, and end with Uvicorn running.

## 5. Connect

- **Claude:** Settings → Connectors → Add custom connector → `https://<your-railway-domain>/mcp`. Leave the advanced OAuth fields empty. On Team/Enterprise an owner adds it once for the org. Each person then clicks Connect, approves the consent page, and signs in with Google.
- **ChatGPT:** add it as a custom MCP connector with OAuth (needs a plan/mode that allows custom connectors).

Test: "Using Steampipe, list S3 buckets in every account and whether they block public access."

## How querying works across accounts

- Each account is its own schema: `aws_prod`, `aws_staging`, ... An aggregator named `aws` combines them all, and because it sorts first, plain table names (`aws_s3_bucket`) query **every account at once**.
- Every row has an `account_id` column, so "group by account" questions just work.
- To target one account, ask for it by name ("in prod only..."). The AI will use `aws_prod.aws_s3_bucket`.
- Adding an account later: deploy the role there, add it to `AWS_ACCOUNTS`, redeploy.

## Managing access

- **Add someone:** add their email or domain to the variables, redeploy.
- **Remove someone:** remove them and redeploy. Their next request is rejected.
- **Audit:** Railway → service → Logs, filter for `audit`. Each line shows the user's email, tool and SQL. In AWS, CloudTrail shows the sessions as `SteampipeHub` / `steampipe-railway`.

## Rotating the certificate (every 90 days)

The server stops working when the client certificate expires; the expiry date is printed at every boot.

1. Put `ca.key` back in `steampipe-pki/`, run `sh make-certs.sh` (it reuses the CA), then remove `ca.key` again.
2. Update `RA_CERT_B64` and `RA_KEY_B64` in Railway and redeploy.

Set a calendar reminder a week before expiry. Use `CERT_DAYS=180 sh make-certs.sh` if 90 days is too frequent.

**Emergency cut-off:** disable the Roles Anywhere profile or trust anchor in the home account (IAM → Roles Anywhere). Access stops within the hour, when the current session expires.

## Notes

- Sign-in records are stored on the container's disk, so after a redeploy teammates may need to click Connect again. If that gets annoying, add Railway's Redis and switch FastMCP's `client_storage` to it.
- Lambda environment variables can still appear via `ListFunctions`. Keep secrets in Secrets Manager, not env vars.
- Query results go to whichever AI provider the teammate uses. Confirm that's OK under your data policy.
- Six accounts multiplies API calls by six. Set `AWS_REGIONS` to only the regions you use, and give the service 2 GB+ RAM. First queries on a big table can take tens of seconds; repeats are cached for a few minutes.
