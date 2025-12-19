#!/bin/bash
#
# MCPJungle Setup Script for Vexor Development
# This consolidates all MCPs into a single gateway
#
# Usage:
#   ./setup-mcpjungle.sh local   - Run on local machine/WSL
#   ./setup-mcpjungle.sh vps     - Run on a VPS for remote access
#

set -e

MODE="${1:-local}"
MCPJUNGLE_PORT="${MCPJUNGLE_PORT:-8080}"

echo "============================================"
echo "  MCPJungle Setup for Vexor Development"
echo "============================================"
echo ""
echo "Mode: $MODE"
echo "Port: $MCPJUNGLE_PORT"
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker not found. Please install Docker first."
    exit 1
fi

# Create directory
MCPJUNGLE_DIR="$HOME/.mcpjungle"
mkdir -p "$MCPJUNGLE_DIR"
cd "$MCPJUNGLE_DIR"

echo "📁 Working directory: $MCPJUNGLE_DIR"

# Download docker-compose based on mode
if [ "$MODE" = "vps" ]; then
    echo "📥 Downloading production docker-compose..."
    curl -sO https://raw.githubusercontent.com/mcpjungle/MCPJungle/refs/heads/main/docker-compose.prod.yaml
    COMPOSE_FILE="docker-compose.prod.yaml"
else
    echo "📥 Downloading development docker-compose..."
    curl -sO https://raw.githubusercontent.com/mcpjungle/MCPJungle/refs/heads/main/docker-compose.yaml
    COMPOSE_FILE="docker-compose.yaml"
fi

# Use stdio image for npx support
export MCPJUNGLE_IMAGE_TAG="latest-stdio"

echo "🐳 Starting MCPJungle..."
docker compose -f "$COMPOSE_FILE" up -d

# Wait for startup
echo "⏳ Waiting for MCPJungle to start..."
sleep 5

# Check health
if curl -sf http://localhost:$MCPJUNGLE_PORT/health > /dev/null; then
    echo "✅ MCPJungle is running!"
else
    echo "❌ MCPJungle failed to start. Check logs with: docker compose logs"
    exit 1
fi

# Install CLI
echo ""
echo "📦 Installing MCPJungle CLI..."
if command -v brew &> /dev/null; then
    brew install mcpjungle/mcpjungle/mcpjungle || true
else
    echo "   Homebrew not available. Download CLI from:"
    echo "   https://github.com/mcpjungle/MCPJungle/releases"
fi

# Create MCP registration configs
echo ""
echo "📝 Creating MCP registration configs..."

# Remote MCPs (HTTP-based)
cat > "$MCPJUNGLE_DIR/solana.json" << 'EOF'
{
  "name": "solana",
  "transport": "streamable_http",
  "description": "Solana MCP - Blockchain development tools",
  "url": "https://mcp.solana.com/mcp"
}
EOF

cat > "$MCPJUNGLE_DIR/context7.json" << 'EOF'
{
  "name": "context7",
  "transport": "streamable_http",
  "description": "Context7 - Up-to-date documentation for LLMs",
  "url": "https://mcp.context7.com/mcp"
}
EOF

cat > "$MCPJUNGLE_DIR/stackoverflow.json" << 'EOF'
{
  "name": "stackoverflow",
  "transport": "streamable_http",
  "description": "Stack Overflow MCP",
  "url": "https://mcp.stackoverflow.com"
}
EOF

# STDIO MCPs (need API keys - fill in before registering)
cat > "$MCPJUNGLE_DIR/github.json" << 'EOF'
{
  "name": "github",
  "transport": "stdio",
  "description": "GitHub MCP - Repository management",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-github"],
  "env": {
    "GITHUB_PERSONAL_ACCESS_TOKEN": "YOUR_GITHUB_TOKEN"
  }
}
EOF

cat > "$MCPJUNGLE_DIR/firecrawl.json" << 'EOF'
{
  "name": "firecrawl",
  "transport": "stdio",
  "description": "Firecrawl - Web scraping and search",
  "command": "npx",
  "args": ["-y", "firecrawl-mcp"],
  "env": {
    "FIRECRAWL_API_KEY": "YOUR_FIRECRAWL_API_KEY"
  }
}
EOF

# Tool Group for Vexor development
cat > "$MCPJUNGLE_DIR/vexor-dev-group.json" << 'EOF'
{
  "name": "vexor-dev",
  "description": "Optimized tool set for Vexor Solana client development",
  "included_servers": ["solana", "github", "context7"],
  "included_tools": [
    "firecrawl__scrape",
    "firecrawl__search",
    "stackoverflow__search"
  ]
}
EOF

echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo ""
echo "1. Edit the config files to add your API keys:"
echo "   nano $MCPJUNGLE_DIR/github.json"
echo "   nano $MCPJUNGLE_DIR/firecrawl.json"
echo ""
echo "2. Register MCPs (after installing CLI):"
echo "   mcpjungle register -c $MCPJUNGLE_DIR/solana.json"
echo "   mcpjungle register -c $MCPJUNGLE_DIR/context7.json"
echo "   mcpjungle register -c $MCPJUNGLE_DIR/stackoverflow.json"
echo "   mcpjungle register -c $MCPJUNGLE_DIR/github.json"
echo "   mcpjungle register -c $MCPJUNGLE_DIR/firecrawl.json"
echo ""
echo "3. Create the Vexor tool group:"
echo "   mcpjungle create group -c $MCPJUNGLE_DIR/vexor-dev-group.json"
echo ""
echo "4. Update your Cursor MCP config (~/.cursor/mcp.json):"
echo ""
if [ "$MODE" = "vps" ]; then
    echo '   {
     "mcpServers": {
       "mcpjungle": {
         "url": "http://YOUR_VPS_IP:'$MCPJUNGLE_PORT'/v0/groups/vexor-dev/mcp",
         "headers": {
           "Authorization": "Bearer YOUR_ACCESS_TOKEN"
         }
       }
     }
   }'
else
    echo '   {
     "mcpServers": {
       "mcpjungle": {
         "url": "http://localhost:'$MCPJUNGLE_PORT'/mcp"
       }
     }
   }'
fi
echo ""
echo "5. List available tools:"
echo "   mcpjungle list tools"
echo ""
echo "============================================"

