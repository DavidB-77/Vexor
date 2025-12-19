# MCPJungle VPS Deployment Plan

## VPS Audit Results

### Server: qstesting.com (148.230.81.56)

| Resource | Current | Available | MCPJungle Needs | Status |
|----------|---------|-----------|-----------------|--------|
| **RAM** | 1.8 GB used | **13 GB free** | ~600 MB | ✅ EXCELLENT |
| **Storage** | 78 GB used | **115 GB free** | ~1-2 GB | ✅ EXCELLENT |
| **CPU** | 4 vCPU | AMD EPYC 9354P | 1 vCPU | ✅ EXCELLENT |
| **Docker** | Installed | Running | Required | ✅ READY |

### Currently Running Services

| Service | Port | Purpose |
|---------|------|---------|
| `snapstream-mcp-server` | 3100 | SnapStream MCP |
| `network-status-api` | 8780 | Network status |
| `snapstream-bot` | N/A | Discord bot |
| `masque-broker` | 8787 | MASQUE protocol |
| `masque-upload-gateway` | 8788 | Upload gateway |
| `snapstream-shred-capture` | 8011 | Shred capture |
| `snapstream-uploader` | 8080 | Uploader |

**⚠️ Port 8080 is in use** - MCPJungle will use a different port (8880)

---

## Deployment Plan

### Phase 1: Prepare MCPJungle (VPS)

```bash
# SSH to VPS
ssh -i ~/.ssh/id_solsnap_vps solsnap@qstesting.com

# Create MCPJungle directory
sudo mkdir -p /opt/mcpjungle
sudo chown solsnap:solsnap /opt/mcpjungle
cd /opt/mcpjungle

# Download docker-compose (dev mode - simpler for single user)
curl -O https://raw.githubusercontent.com/mcpjungle/MCPJungle/refs/heads/main/docker-compose.yaml

# Modify port to avoid conflict with snapstream-uploader (8080)
sed -i 's/"8080:8080"/"8880:8080"/g' docker-compose.yaml

# Use stdio image for npx support
export MCPJUNGLE_IMAGE_TAG=latest-stdio

# Start MCPJungle
docker compose up -d

# Verify
curl http://localhost:8880/health
```

### Phase 2: Install CLI (VPS)

```bash
# Install MCPJungle CLI (binary download)
curl -L https://github.com/mcpjungle/MCPJungle/releases/latest/download/mcpjungle_linux_amd64.tar.gz -o /tmp/mcpjungle.tar.gz
tar -xzf /tmp/mcpjungle.tar.gz -C /tmp
sudo mv /tmp/mcpjungle /usr/local/bin/
chmod +x /usr/local/bin/mcpjungle

# Verify
mcpjungle version
```

### Phase 3: Register MCP Servers

#### Remote MCPs (HTTP-based, no npx needed)

```bash
# Context7 - Up-to-date documentation
mcpjungle register --name context7 --url https://mcp.context7.com/mcp

# Solana MCP - Blockchain development
mcpjungle register --name solana --url https://mcp.solana.com/mcp

# Stack Overflow - Q&A
mcpjungle register --name stackoverflow --url https://mcp.stackoverflow.com

# Your existing SnapStream MCP (already running!)
mcpjungle register --name snapstream --url http://localhost:3100/mcp
```

#### STDIO MCPs (npx-based)

Create config files first:

```bash
# GitHub MCP
cat > /opt/mcpjungle/github.json << 'EOF'
{
  "name": "github",
  "transport": "stdio",
  "description": "GitHub repository management",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-github"],
  "env": {
    "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_YOUR_TOKEN_HERE"
  }
}
EOF

# Firecrawl MCP
cat > /opt/mcpjungle/firecrawl.json << 'EOF'
{
  "name": "firecrawl",
  "transport": "stdio",
  "description": "Web scraping and search",
  "command": "npx",
  "args": ["-y", "firecrawl-mcp"],
  "env": {
    "FIRECRAWL_API_KEY": "fc-YOUR_KEY_HERE"
  }
}
EOF

# Memory MCP (knowledge graph)
cat > /opt/mcpjungle/memory.json << 'EOF'
{
  "name": "memory",
  "transport": "stdio",
  "description": "Knowledge graph persistence",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-memory"]
}
EOF

# Sequential Thinking MCP
cat > /opt/mcpjungle/thinking.json << 'EOF'
{
  "name": "thinking",
  "transport": "stdio",
  "description": "Complex problem solving",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-sequentialthinking"]
}
EOF

# Register all
mcpjungle register -c /opt/mcpjungle/github.json
mcpjungle register -c /opt/mcpjungle/firecrawl.json
mcpjungle register -c /opt/mcpjungle/memory.json
mcpjungle register -c /opt/mcpjungle/thinking.json

# List registered servers
mcpjungle list servers
```

### Phase 4: Create Tool Groups

#### Group 1: vexor-core (Daily Development)

```bash
cat > /opt/mcpjungle/group-vexor-core.json << 'EOF'
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
EOF

mcpjungle create group -c /opt/mcpjungle/group-vexor-core.json
```

**Endpoint**: `http://qstesting.com:8880/v0/groups/vexor-core/mcp`

#### Group 2: research (Research Mode)

```bash
cat > /opt/mcpjungle/group-research.json << 'EOF'
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
EOF

mcpjungle create group -c /opt/mcpjungle/group-research.json
```

**Endpoint**: `http://qstesting.com:8880/v0/groups/research/mcp`

#### Group 3: thinking (Complex Problems)

```bash
cat > /opt/mcpjungle/group-thinking.json << 'EOF'
{
  "name": "thinking",
  "description": "Deep analysis and problem-solving",
  "included_tools": [
    "thinking__sequentialthinking",
    "memory__create_entities",
    "memory__add_observations",
    "memory__search_nodes",
    "context7__get-library-docs"
  ]
}
EOF

mcpjungle create group -c /opt/mcpjungle/group-thinking.json
```

**Endpoint**: `http://qstesting.com:8880/v0/groups/thinking/mcp`

#### Group 4: snapstream (SnapStream Work)

```bash
cat > /opt/mcpjungle/group-snapstream.json << 'EOF'
{
  "name": "snapstream",
  "description": "SnapStream project tools",
  "included_servers": ["snapstream", "github"],
  "included_tools": [
    "context7__resolve-library-id",
    "context7__get-library-docs",
    "firecrawl__scrape"
  ]
}
EOF

mcpjungle create group -c /opt/mcpjungle/group-snapstream.json
```

**Endpoint**: `http://qstesting.com:8880/v0/groups/snapstream/mcp`

### Phase 5: Verify Setup

```bash
# List all tools
mcpjungle list tools

# List tools in vexor-core group
mcpjungle list tools --group vexor-core

# Test a tool call
mcpjungle invoke context7__resolve-library-id --input '{"libraryName": "zig"}'
```

### Phase 6: Setup Systemd Service (Persistence)

```bash
sudo tee /etc/systemd/system/mcpjungle.service << 'EOF'
[Unit]
Description=MCPJungle MCP Gateway
Requires=docker.service
After=docker.service

[Service]
Type=simple
User=solsnap
WorkingDirectory=/opt/mcpjungle
Environment=MCPJUNGLE_IMAGE_TAG=latest-stdio
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=unless-stopped
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mcpjungle
sudo systemctl start mcpjungle
sudo systemctl status mcpjungle
```

---

## Cursor Configuration

### Option A: Single Group (Simple)

Update `~/.cursor/mcp.json` on your WSL machine:

```json
{
  "mcpServers": {
    "mcpjungle": {
      "url": "http://qstesting.com:8880/v0/groups/vexor-core/mcp"
    }
  }
}
```

### Option B: Multiple Groups (Switch Based on Task)

```json
{
  "mcpServers": {
    "vexor": {
      "url": "http://qstesting.com:8880/v0/groups/vexor-core/mcp"
    },
    "research": {
      "url": "http://qstesting.com:8880/v0/groups/research/mcp"
    },
    "thinking": {
      "url": "http://qstesting.com:8880/v0/groups/thinking/mcp"
    },
    "snapstream": {
      "url": "http://qstesting.com:8880/v0/groups/snapstream/mcp"
    }
  }
}
```

**Note**: With Option B, you'll have 4 MCP "slots" but each exposes a focused set of tools.

### Option C: Hybrid (MCPJungle + Local)

Keep your custom Zig MCP local (since it's custom), everything else via MCPJungle:

```json
{
  "mcpServers": {
    "mcpjungle": {
      "url": "http://qstesting.com:8880/v0/groups/vexor-core/mcp"
    },
    "zig": {
      "command": "/home/dbdev/.nvm/versions/node/v22.17.0/bin/node",
      "args": ["/home/dbdev/zig-mcp-server/build/index.js"],
      "env": {
        "GITHUB_TOKEN": "ghp_YOUR_TOKEN",
        "NODE_OPTIONS": "--experimental-vm-modules"
      }
    }
  }
}
```

---

## Security Considerations

### Firewall (Optional but Recommended)

```bash
# Only allow specific IPs to MCPJungle port
sudo ufw allow from YOUR_HOME_IP to any port 8880
sudo ufw deny 8880
```

### Bearer Token Auth (For Enterprise Mode)

If you upgrade to enterprise mode later:

```bash
# Re-deploy with enterprise mode
export SERVER_MODE=enterprise
docker compose down
docker compose up -d

# Initialize admin
mcpjungle init-server

# Create client token
mcpjungle create mcp-client cursor --allow "vexor-core,research,thinking"

# Use token in Cursor config:
# "headers": {"Authorization": "Bearer YOUR_TOKEN"}
```

---

## Resource Monitoring

After deployment, monitor with:

```bash
# Docker stats
docker stats mcpjungle-server mcpjungle-db

# Disk usage
du -sh /opt/mcpjungle/

# Logs
docker compose -f /opt/mcpjungle/docker-compose.yaml logs -f --tail 100
```

Expected usage:
- **RAM**: ~400-600 MB (MCPJungle + SQLite)
- **Disk**: ~500 MB (images + data)
- **Network**: Minimal (HTTP requests)

---

## Rollback Plan

If issues occur:

```bash
# Stop MCPJungle
docker compose -f /opt/mcpjungle/docker-compose.yaml down

# Remove containers
docker rm -f mcpjungle-server mcpjungle-db 2>/dev/null

# Restore original Cursor config
# (use your current mcp.json backup)

# MCPJungle data persists in /opt/mcpjungle/ for future use
```

---

## Summary

| Step | Time | Risk |
|------|------|------|
| 1. Deploy MCPJungle | 5 min | Low |
| 2. Install CLI | 2 min | Low |
| 3. Register MCPs | 5 min | Low |
| 4. Create Groups | 5 min | Low |
| 5. Test locally | 5 min | Low |
| 6. Update Cursor | 2 min | Low (can revert) |
| 7. Verify end-to-end | 5 min | Low |

**Total**: ~30 minutes

**Your VPS has plenty of resources** - this won't impact SnapStream services at all.

