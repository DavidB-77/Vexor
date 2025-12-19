# MCPJungle Deep Dive: Tool Groups, Limits, and Strategy

## Overview

MCPJungle is NOT just "throw all MCPs together." Understanding **Tool Groups** is critical to avoiding the same tool limit issues you'd have in Cursor directly.

---

## Tool Count Analysis

| MCP Server | Tools | Size | Use Case |
|------------|-------|------|----------|
| **Memory** | 9 | 54 MB | Persistent knowledge graph |
| **Filesystem** | 11 | 60 MB | Local file operations |
| **Sequential Thinking** | 1 | 54 MB | Complex problem solving |
| **Context7** | 2 | ~50 MB | Up-to-date documentation |
| **GitHub** | ~15 | via npx | Repository management |
| **Firecrawl** | 5 | via npx | Web scraping/search |
| **Solana** | ~10 | Remote | Blockchain development |
| **Stack Overflow** | ~3 | Remote | Q&A search |

**Total if all combined: ~56+ tools**

This would STILL overwhelm most AI assistants! Hence: **Tool Groups**.

---

## MCPJungle Tool Groups: The Key Feature

### What Are Tool Groups?

Tool Groups let you create **focused subsets** of tools that are exposed via a unique endpoint.

```
MCPJungle Gateway
├── /mcp                          (ALL tools - 56+)
├── /v0/groups/vexor-core/mcp     (8 tools)
├── /v0/groups/research/mcp       (7 tools)
└── /v0/groups/filesystem/mcp     (11 tools)
```

### Why This Matters

1. **AI Context Window**: Fewer tools = more context for actual code
2. **Better Tool Selection**: AI picks the right tool more often
3. **Faster Responses**: Less tool enumeration overhead
4. **Task-Specific Configs**: Switch groups based on what you're doing

---

## Recommended Tool Groups for Vexor Development

### Group 1: `vexor-core` (Daily Development)

**Endpoint**: `http://your-vps:8080/v0/groups/vexor-core/mcp`

```json
{
  "name": "vexor-core",
  "description": "Core tools for Vexor Solana client development",
  "included_servers": ["solana", "github"],
  "included_tools": [
    "context7__resolve-library-id",
    "context7__get-library-docs",
    "firecrawl__scrape",
    "firecrawl__search"
  ]
}
```

**Tools Exposed**: ~8-10
**Use When**: Writing Vexor code, checking Solana docs, managing repo

---

### Group 2: `research` (Deep Research Mode)

**Endpoint**: `http://your-vps:8080/v0/groups/research/mcp`

```json
{
  "name": "research",
  "description": "Research and documentation lookup",
  "included_servers": ["context7", "stackoverflow"],
  "included_tools": [
    "firecrawl__scrape",
    "firecrawl__search",
    "firecrawl__map",
    "memory__search_nodes",
    "memory__read_graph"
  ]
}
```

**Tools Exposed**: ~7
**Use When**: Researching new features, debugging unknown errors

---

### Group 3: `thinking` (Complex Problem Solving)

**Endpoint**: `http://your-vps:8080/v0/groups/thinking/mcp`

```json
{
  "name": "thinking",
  "description": "Deep analysis and problem-solving",
  "included_tools": [
    "sequentialthinking__sequentialthinking",
    "memory__create_entities",
    "memory__add_observations",
    "memory__search_nodes",
    "context7__get-library-docs"
  ]
}
```

**Tools Exposed**: 5
**Use When**: Architecture decisions, debugging complex issues

---

### Group 4: `filesystem` (Local File Operations)

**Endpoint**: `http://your-vps:8080/v0/groups/filesystem/mcp`

```json
{
  "name": "filesystem",
  "description": "Local file system access",
  "included_servers": ["filesystem"]
}
```

**Tools Exposed**: 11
**Use When**: Bulk file operations, project restructuring

⚠️ **Note**: This requires mounting local filesystem to MCPJungle container

---

## MCP Details

### Memory MCP (Knowledge Graph)

**9 Tools:**
| Tool | Description |
|------|-------------|
| `create_entities` | Create new entities in knowledge graph |
| `create_relations` | Link entities together |
| `add_observations` | Add facts to existing entities |
| `delete_entities` | Remove entities |
| `delete_relations` | Remove links |
| `delete_observations` | Remove facts |
| `open_nodes` | Get specific nodes by name |
| `read_graph` | Read entire knowledge graph |
| `search_nodes` | Search by query |

**Use Cases for Vexor:**
- Remember project conventions across sessions
- Track which modules have been reviewed
- Store debugging insights for recurring issues
- Keep notes on Solana protocol quirks

**Storage**: Persistent JSON file (persists across restarts)

---

### Filesystem MCP

**11 Tools:**
| Tool | Description |
|------|-------------|
| `read_file` | Read single file contents |
| `read_multiple_files` | Read many files at once |
| `write_file` | Create/overwrite file |
| `edit_file` | Line-based edits (like search_replace) |
| `create_directory` | Make directories |
| `list_directory` | List dir contents |
| `directory_tree` | Recursive tree view |
| `search_files` | Find files by pattern |
| `move_file` | Move/rename files |
| `get_file_info` | File metadata |
| `list_allowed_directories` | Show accessible paths |

**⚠️ Docker Caveat**: MCPJungle in Docker needs volume mounts:
```yaml
volumes:
  - /home/dbdev/solana-client-research:/host/vexor:ro
```

**Why You Might Want This**:
- Cursor already has file access, so this is mostly for:
  - Accessing files on VPS that aren't in Cursor workspace
  - Bulk operations across many files
  - When MCPJungle is running remotely

---

### Sequential Thinking MCP

**1 Tool** (but powerful):
| Tool | Description |
|------|-------------|
| `sequentialthinking` | Multi-step problem solving with revision |

**Key Features:**
- Can revise previous thoughts
- Can branch into alternative approaches
- Generates and verifies hypotheses
- Tracks uncertainty

**Use Cases for Vexor:**
- Complex architecture decisions
- Debugging multi-module issues
- Planning major refactors

---

### Context7 MCP

**2 Tools:**
| Tool | Description |
|------|-------------|
| `resolve-library-id` | Find library ID for docs |
| `get-library-docs` | Fetch current documentation |

**Key Benefit**: Real-time docs prevent hallucinated APIs

**Libraries with Context7 Support:**
- Zig standard library
- Rust crates (tokio, serde, etc.)
- Solana SDK
- Many more

---

## VPS Resource Requirements

### MCPJungle Production Setup

From `docker-compose.prod.yaml`:

```yaml
services:
  db:          # PostgreSQL
  pgadmin:     # Database GUI (optional)
  mcpjungle:   # Main gateway
  prometheus:  # Metrics (optional)
```

### Minimum VPS Specs

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **vCPU** | 1 | 2 |
| **RAM** | 1 GB | 2 GB |
| **Storage** | 10 GB | 20 GB |
| **Network** | 1 Gbps | 1 Gbps |

### Resource Usage Breakdown

| Component | RAM | Storage | Notes |
|-----------|-----|---------|-------|
| MCPJungle | ~100 MB | ~50 MB | Main gateway |
| PostgreSQL | ~200 MB | ~100 MB | Database |
| Docker overhead | ~200 MB | ~500 MB | Runtime |
| MCP Images | ~50-60 MB each | ~300 MB total | Cached |
| **Total Base** | **~600 MB** | **~1 GB** | Without stdio servers |

### STDIO Servers (npx-based) Add More Load

Each STDIO server spawns a Node.js process per tool call:
- GitHub MCP: +~50-100 MB per call
- Firecrawl MCP: +~50-100 MB per call

**Recommendation**: Use remote/HTTP MCPs when possible to avoid process spawning.

---

## Your Existing VPS Assessment

**Questions to answer:**
1. What VPS provider? (Hetzner, DO, Vultr, etc.)
2. How much RAM/CPU currently?
3. What's already running on it?
4. Is Docker already installed?

**Safe to run MCPJungle if:**
- At least 1 GB free RAM
- At least 5 GB free storage
- Docker installed or can be installed

---

## Cursor Rules for MCP Priority

Add this to your `.cursorrules` to guide MCP usage:

```markdown
## MCP Usage Guidelines

### Available MCPs (via MCPJungle groups)

1. **vexor-core** (default for coding)
   - Solana docs, GitHub, Context7, Firecrawl
   - Use for: Daily development, code changes

2. **research** (switch when researching)
   - Context7, Stack Overflow, Firecrawl, Memory
   - Use for: Unknown errors, new features research

3. **thinking** (switch for complex problems)
   - Sequential Thinking, Memory, Context7
   - Use for: Architecture decisions, complex debugging

### MCP Priority Order

When multiple tools could work:
1. **Context7** - Always prefer for documentation lookups
2. **Solana MCP** - For blockchain-specific questions
3. **GitHub MCP** - For repository operations only
4. **Firecrawl** - Only when Context7 doesn't have the info
5. **Memory** - For cross-session persistence needs

### When to Switch Groups

- Starting new feature → `vexor-core`
- Hit unknown error → switch to `research`
- Complex design decision → switch to `thinking`
- Need file operations → switch to `filesystem`
```

---

## Implementation Steps

### Phase 1: Test Locally (Before VPS)

```bash
# In WSL
cd ~
curl -O https://raw.githubusercontent.com/mcpjungle/MCPJungle/refs/heads/main/docker-compose.yaml
docker compose up -d

# Install CLI
brew install mcpjungle/mcpjungle/mcpjungle

# Register remote MCPs (no npx needed)
mcpjungle register --name context7 --url https://mcp.context7.com/mcp
mcpjungle register --name solana --url https://mcp.solana.com/mcp
mcpjungle register --name stackoverflow --url https://mcp.stackoverflow.com

# Create a small test group
cat > test-group.json << 'EOF'
{
  "name": "test",
  "description": "Test group",
  "included_servers": ["context7", "solana"]
}
EOF
mcpjungle create group -c test-group.json

# List tools
mcpjungle list tools --group test

# Test in Cursor with:
# {"mcpServers": {"test": {"url": "http://localhost:8080/v0/groups/test/mcp"}}}
```

### Phase 2: Deploy to VPS

```bash
# On VPS
curl -O https://raw.githubusercontent.com/mcpjungle/MCPJungle/refs/heads/main/docker-compose.prod.yaml

# Customize if needed (remove pgadmin/prometheus to save resources)
docker compose -f docker-compose.prod.yaml up -d

# Initialize admin
mcpjungle init-server

# Register MCPs and groups (same as local)
```

### Phase 3: Secure Remote Access

```bash
# Create access token for Cursor
mcpjungle create mcp-client cursor --allow "vexor-core,research,thinking"

# Note the token, use in Cursor config:
# "headers": {"Authorization": "Bearer YOUR_TOKEN"}
```

---

## Limitations to Know

### Current MCPJungle Limitations

1. **No persistent STDIO connections** - Each tool call spawns new process
2. **No OAuth flow yet** - Use bearer tokens for auth
3. **Tool Groups don't support Prompts** - Only tools
4. **Can't update groups** - Must delete and recreate

### Workarounds

| Limitation | Workaround |
|------------|------------|
| STDIO overhead | Use HTTP/remote MCPs when possible |
| No OAuth | Use API tokens (GitHub PAT, Firecrawl key) |
| Group updates | Script group recreation |

---

## Summary: Start Small, Scale Smart

1. **Don't add everything at once** - Start with 2-3 MCPs
2. **Test locally first** - Verify before VPS deployment
3. **Use Tool Groups** - Never expose all 50+ tools
4. **Monitor resources** - Watch RAM on VPS
5. **Update .cursorrules** - Document which group to use when

