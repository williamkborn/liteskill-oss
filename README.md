# Liteskill

A self-hosted AI chat application built with Elixir and Phoenix. Liteskill connects to AWS Bedrock LLMs (Claude by default) and supports real-time streaming, conversation branching, and external tool execution via the Model Context Protocol (MCP).

## Features

- **Streaming chat** -- Real-time token-by-token responses via Phoenix LiveView
- **MCP tool support** -- Connect external tool servers so the AI can call APIs, query databases, and more
- **Conversation forking** -- Branch any conversation at any message to explore alternate paths
- **Event sourcing** -- Every state change is an immutable event, giving you a full audit trail and the ability to replay or rebuild state
- **Dual authentication** -- OpenID Connect (SSO) and password-based registration
- **Access control** -- Share conversations with specific users or groups via ACLs
- **Encrypted secrets** -- MCP API keys are encrypted at rest using AES-256-GCM

## Prerequisites

- [mise](https://mise.jdx.dev/) (manages Elixir, Erlang, and Node versions)
- PostgreSQL 14+

The project pins its toolchain via `mise.toml`:

| Tool   | Version |
|--------|---------|
| Elixir | 1.18    |
| Erlang | 28      |
| Node   | 24      |

## Getting Started

```bash
# Clone the repository
git clone https://github.com/your-org/liteskill-oss.git
cd liteskill-oss

# Install tool versions (Elixir, Erlang, Node)
mise install

# Install dependencies, create the database, run migrations, and build assets
mise exec -- mix setup

# Start the development server
mise exec -- mix phx.server
```

Visit [localhost:4000](http://localhost:4000) in your browser.

## Configuration

All runtime configuration is loaded from environment variables. Set them before starting the server or add them to a `.env` file.

### Required (production)

| Variable          | Description                          |
|-------------------|--------------------------------------|
| `DATABASE_URL`    | PostgreSQL connection string         |
| `SECRET_KEY_BASE` | Phoenix signing/encryption key       |
| `ENCRYPTION_KEY`  | Encryption key for secrets at rest   |

### Optional

| Variable                  | Description                              | Default                                                 |
|---------------------------|------------------------------------------|---------------------------------------------------------|
| `PORT`                    | HTTP port                                | `4000`                                                  |
| `PHX_HOST`                | Public hostname                          | `example.com`                                           |
| `PHX_SERVER`              | Set to `true` to start the HTTP server   | --                                                      |
| `AWS_BEARER_TOKEN_BEDROCK`| AWS Bedrock bearer token                 | --                                                      |
| `AWS_REGION`              | AWS region for Bedrock                   | `us-east-1`                                             |
| `OIDC_ISSUER`             | OpenID Connect issuer URL                | --                                                      |
| `OIDC_CLIENT_ID`          | OIDC client ID                           | --                                                      |
| `OIDC_CLIENT_SECRET`      | OIDC client secret                       | --                                                      |

## Development

```bash
# Run the full pre-commit suite (compile, format, test)
mise exec -- mix precommit

# Run tests
mise exec -- mix test

# Run a single test file
mise exec -- mix test test/liteskill/chat_test.exs

# Reset the database
mise exec -- mix ecto.reset
```

### Project Structure

```
lib/
  liteskill/
    aggregate/          # Event sourcing: aggregate behaviour and loader
    chat/               # Chat context: conversations, messages, projector, events
    event_store/        # Append-only event store with optimistic concurrency
    llm/                # AWS Bedrock client, streaming handler, event-stream parser
    mcp_servers/        # MCP server registry and JSON-RPC 2.0 client
    accounts/           # User management (OIDC + password auth)
    groups/             # Group memberships for ACL
    crypto/             # AES-256-GCM encryption for sensitive fields
  liteskill_web/
    live/               # LiveView: chat UI, auth
    controllers/        # REST API for conversations, groups, auth
    plugs/              # Authentication plugs
```

### Architecture

Liteskill uses event sourcing with CQRS. The write path flows through aggregates and the event store; the read path queries projection tables maintained by a GenServer projector.

```
Command -> Aggregate -> EventStore (append) -> PubSub -> Projector -> Projection Tables
                                                       -> LiveView (real-time UI updates)
```

The `ConversationAggregate` enforces a state machine: **created -> active <-> streaming -> archived**. Tool calls are handled during streaming, with support for both automatic execution and manual approval via the UI.

## API

Liteskill exposes a JSON API under `/api` for programmatic access. All endpoints require session authentication.

| Method   | Path                                      | Description                 |
|----------|-------------------------------------------|-----------------------------|
| `GET`    | `/api/conversations`                      | List conversations          |
| `POST`   | `/api/conversations`                      | Create a conversation       |
| `GET`    | `/api/conversations/:id`                  | Get conversation + messages |
| `POST`   | `/api/conversations/:id/messages`         | Send a message              |
| `POST`   | `/api/conversations/:id/fork`             | Fork at a message position  |
| `POST`   | `/api/conversations/:id/acls`             | Grant user/group access     |
| `DELETE` | `/api/conversations/:id/acls/:user_id`    | Revoke access               |
| `DELETE` | `/api/conversations/:id/membership`       | Leave a shared conversation |
| `GET`    | `/api/groups`                             | List groups                 |
| `POST`   | `/api/groups`                             | Create a group              |
| `GET`    | `/api/groups/:id`                         | Get group details           |
| `DELETE` | `/api/groups/:id`                         | Delete a group              |
| `POST`   | `/api/groups/:id/members`                 | Add a member                |
| `DELETE` | `/api/groups/:id/members/:user_id`        | Remove a member             |

## Deployment

Build a release:

```bash
MIX_ENV=prod mise exec -- mix assets.deploy
MIX_ENV=prod mise exec -- mix release
```

Run it:

```bash
DATABASE_URL="ecto://..." \
SECRET_KEY_BASE="$(mix phx.gen.secret)" \
ENCRYPTION_KEY="$(mix phx.gen.secret)" \
PHX_HOST="your-domain.com" \
PHX_SERVER=true \
_build/prod/rel/liteskill/bin/liteskill start
```

See the [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html) for more options including Docker and fly.io.

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
