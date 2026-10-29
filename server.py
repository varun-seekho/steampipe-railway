"""
Steampipe MCP behind Google OAuth.

Claude / ChatGPT  --HTTPS + OAuth-->  this FastMCP server  --stdio-->  @turbot/steampipe-mcp  -->  Steampipe  -->  AWS
"""

import logging
import os
import shlex

from fastmcp import FastMCP
from fastmcp.client.transports import StdioTransport
from fastmcp.exceptions import AuthorizationError
from fastmcp.server.auth import AuthContext
from fastmcp.server.auth.providers.google import GoogleProvider
from fastmcp.server.dependencies import get_access_token
from fastmcp.server.middleware import AuthMiddleware, Middleware, MiddlewareContext
from fastmcp.server.providers.proxy import ProxyClient, ProxyProvider

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
audit = logging.getLogger("audit")


def env_set(name: str) -> set[str]:
    return {v.strip().lower() for v in os.environ.get(name, "").split(",") if v.strip()}


ALLOWED_DOMAINS = env_set("ALLOWED_EMAIL_DOMAINS")  # e.g. "yourcompany.com"
ALLOWED_EMAILS = env_set("ALLOWED_EMAILS")          # e.g. "a@x.com,b@y.com"
if not ALLOWED_DOMAINS and not ALLOWED_EMAILS:
    raise SystemExit("Set ALLOWED_EMAIL_DOMAINS and/or ALLOWED_EMAILS, otherwise any Google account could sign in.")


def current_email() -> str:
    token = get_access_token()
    return ((token.claims.get("email") if token else None) or "unknown").lower()


def allowed_user(ctx: AuthContext) -> bool:
    """Only verified Google accounts on the allowlist may see or call tools."""
    if ctx.token is None:
        raise AuthorizationError("Sign-in required.")
    email = (ctx.token.claims.get("email") or "").lower()
    verified = ctx.token.claims.get("email_verified") in (True, "true")
    domain = email.rsplit("@", 1)[-1] if "@" in email else ""
    if verified and (email in ALLOWED_EMAILS or domain in ALLOWED_DOMAINS):
        return True
    raise AuthorizationError(f"{email or 'This account'} is not allowed to use this server.")


class AuditLog(Middleware):
    """Logs who ran which tool (including the SQL) to Railway's logs."""

    async def on_call_tool(self, context: MiddlewareContext, call_next):
        msg = context.message
        audit.info("user=%s tool=%s args=%s", current_email(), msg.name, msg.arguments)
        return await call_next(context)


auth = GoogleProvider(
    client_id=os.environ["GOOGLE_CLIENT_ID"],
    client_secret=os.environ["GOOGLE_CLIENT_SECRET"],
    base_url=os.environ["PUBLIC_URL"],  # e.g. https://your-app.up.railway.app
    required_scopes=["openid", "https://www.googleapis.com/auth/userinfo.email"],
    jwt_signing_key=os.environ["JWT_SIGNING_KEY"],
    cache_ttl_seconds=300,
)

# One long-lived steampipe-mcp process, shared by all requests. It only runs
# read-only SQL against the local Steampipe database, so there is no per-user
# session state to leak, and we avoid starting Node on every tool call.
backend_cmd = shlex.split(os.environ.get("BACKEND_CMD", "npx @turbot/steampipe-mcp"))
# Pass only what the child needs (not the AWS or Google secrets).
child_env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME") or k.startswith("STEAMPIPE_")}
backend = ProxyClient(StdioTransport(command=backend_cmd[0], args=backend_cmd[1:], env=child_env))
shared_backend = backend.new()

mcp = FastMCP(
    "Steampipe AWS",
    instructions="Query AWS resources with Steampipe SQL. Read-only.",
    auth=auth,
    providers=[ProxyProvider(lambda: shared_backend)],
    middleware=[AuthMiddleware(auth=allowed_user), AuditLog()],
)

if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
