# MCP Optimization Guide for Vexor Development

## Overview

This guide documents strategies to optimize MCP (Model Context Protocol) usage for Vexor development, reducing token costs and improving development speed.

## Current MCP Setup

| MCP Server | Type | Purpose |
|------------|------|---------|
| `github` | npx (stdio) | Repository management, PRs, issues |
| `solanaMcp` | Remote | Solana blockchain development |
| `firecrawl-mcp` | npx (stdio) | Web scraping and search |
| `stack-overflow` | Remote | Developer Q&A |
| `zig` | Local (custom) | Zig language assistance |

## Problem: Cursor MCP Limitations

1. **Tool Limit**: Cursor has limits on visible MCP tools
2. **Resource Usage**: Each npx MCP spawns a separate process
3. **Fragmented Access**: Each MCP is a separate connection
4. **No Caching**: Repeated requests hit the same endpoints

## Solution: MCP Gateway Consolidation

### Option 1: MCPJungle (Recommended)

**[MCPJungle](https://github.com/mcpjungle/MCPJungle)** is a self-hosted MCP Gateway that:

- Consolidates all MCPs into ONE Cursor slot
- Supports Tool Groups (expose only specific tools)
- Can run locally or on a VPS
- Provides unified logging and monitoring

#### Quick Start

```bash
# Local setup
./scripts/setup-mcpjungle.sh local

# VPS setup (for remote access)
./scripts/setup-mcpjungle.sh vps
```

#### Cursor Configuration (Single Slot)

```json
{
  "mcpServers": {
    "mcpjungle": {
      "url": "http://localhost:8080/mcp"
    }
  }
}
```

### Option 2: Docker MCP Gateway

**[Docker MCP](https://github.com/docker/mcp-gateway)** is Docker's official MCP solution:

- Requires Docker Desktop
- Built-in secrets management
- OAuth handling
- Extensive catalog of pre-built MCPs

### Option 3: Hybrid Approach

Run critical MCPs locally, consolidate others via gateway:

```json
{
  "mcpServers": {
    "mcpjungle": {
      "url": "http://your-vps:8080/v0/groups/vexor-dev/mcp"
    },
    "zig": {
      "command": "node",
      "args": ["/path/to/zig-mcp-server/build/index.js"]
    }
  }
}
```

## Recommended MCPs for Vexor Development

### Essential (Currently Using)

| MCP | Purpose |
|-----|---------|
| Solana MCP | Blockchain development, documentation |
| GitHub MCP | Repository management |
| Firecrawl | Web research |

### Recommended Additions

| MCP | Purpose | Token Savings |
|-----|---------|---------------|
| **Context7** | Up-to-date documentation | **High** - Prevents hallucinated APIs |
| **Memory** | Session persistence | Medium - Remembers project context |
| **Sequential Thinking** | Better reasoning | Medium - Improved problem solving |

## Context7: The Game Changer

Context7 provides real-time, version-specific documentation to LLMs. This is critical for:

- **Zig 0.13**: Rapidly evolving API
- **Solana**: Frequent SDK updates
- **Anchor**: Framework-specific patterns

### Add Context7 Now

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

### Usage Example

When asking Claude about Zig or Solana:

```
Use context7 to get the documentation for `std.ArrayList` in Zig 0.13
```

Claude will fetch current, accurate documentation instead of relying on training data.

## Tool Groups Strategy

For Vexor development, create focused tool groups:

### `vexor-dev` Group

```json
{
  "name": "vexor-dev",
  "description": "Core tools for Vexor development",
  "included_servers": ["solana", "github", "context7"],
  "included_tools": [
    "firecrawl__scrape",
    "firecrawl__search"
  ]
}
```

### `research` Group

```json
{
  "name": "research",
  "description": "Research and documentation tools",
  "included_servers": ["context7", "stackoverflow"],
  "included_tools": [
    "firecrawl__scrape",
    "firecrawl__map"
  ]
}
```

## Cost Analysis

| Scenario | MCP Calls | Tokens Used | Notes |
|----------|-----------|-------------|-------|
| Without Context7 | Same | Higher | More debugging cycles |
| With Context7 | Same | **Lower** | Accurate code first time |
| MCPJungle Local | Same | Same | Better organization |
| MCPJungle VPS | Same | Same | Remote access |

**Key Insight**: The biggest token savings come from **accuracy**, not fewer MCP calls. Context7 reduces hallucinations → fewer debugging iterations → fewer tokens.

## VPS Deployment Guide

### Recommended VPS Providers

| Provider | Cost | Notes |
|----------|------|-------|
| Hetzner | $4/mo | Best value, EU-based |
| DigitalOcean | $6/mo | Easy setup |
| Vultr | $5/mo | Global locations |
| Linode | $5/mo | Good performance |

### Minimum Requirements

- 1 vCPU
- 1GB RAM
- 25GB SSD
- Ubuntu 22.04+

### Security Considerations

1. Use bearer token authentication
2. Restrict IP access via firewall
3. Use HTTPS with Let's Encrypt
4. Regular updates

## References

- [MCPJungle GitHub](https://github.com/mcpjungle/MCPJungle)
- [Docker MCP Gateway](https://github.com/docker/mcp-gateway)
- [Docker MCP Catalog](https://hub.docker.com/search?q=mcp&type=image)
- [Self-Hosted MCP Guide](https://selfhostedmcp.com/)
- [MCP Servers Comparison](https://www.shuttle.dev/blog/2025/09/15/mcp-servers-rust-comparison)
- [Model Context Protocol Spec](https://modelcontextprotocol.io/)

