#!/bin/bash
# VEXOR Deployment Script
# Deploys VEXOR to validator server and sets up necessary scripts

set -e

SERVER="38.92.24.174"
SERVER_USER="root"
VEXOR_BINARY="zig-out/bin/vexor"
REMOTE_BINARY="/home/sol/vexor/bin/vexor-validator"

echo "=== VEXOR Deployment Script ==="
echo ""

# Step 1: Verify binary exists
if [ ! -f "$VEXOR_BINARY" ]; then
    echo "ERROR: VEXOR binary not found at $VEXOR_BINARY"
    echo "Please build first: zig build -Doptimize=ReleaseFast"
    exit 1
fi

echo "✓ Found VEXOR binary: $VEXOR_BINARY"
echo ""

# Step 2: Test SSH connection
echo "Testing SSH connection to $SERVER_USER@$SERVER..."
if ! ssh -o ConnectTimeout=5 "$SERVER_USER@$SERVER" "echo 'Connection successful'" 2>/dev/null; then
    echo ""
    echo "ERROR: Cannot connect to server. Please ensure:"
    echo "  1. SSH keys are set up: ssh-copy-id $SERVER_USER@$SERVER"
    echo "  2. Or use password authentication"
    echo ""
    echo "You can also run these commands manually:"
    echo ""
    echo "# Copy binary:"
    echo "scp $VEXOR_BINARY $SERVER_USER@$SERVER:$REMOTE_BINARY"
    echo ""
    echo "# Then SSH and run setup:"
    echo "ssh $SERVER_USER@$SERVER"
    exit 1
fi

echo "✓ SSH connection successful"
echo ""

# Step 3: Create remote directories
echo "Creating remote directories..."
ssh "$SERVER_USER@$SERVER" << 'REMOTE_EOF'
mkdir -p /home/sol/vexor/bin
mkdir -p /home/sol/vexor/config
mkdir -p /home/sol/scripts
mkdir -p /home/sol/logs
chown -R sol:sol /home/sol/vexor /home/sol/scripts /home/sol/logs
REMOTE_EOF
echo "✓ Remote directories created"
echo ""

# Step 4: Copy binary (rename to vexor-validator on server)
echo "Copying VEXOR binary to server..."
scp "$VEXOR_BINARY" "$SERVER_USER@$SERVER:$REMOTE_BINARY"
echo "✓ Binary copied as vexor-validator"
echo ""

# Step 5: Set permissions
echo "Setting binary permissions..."
ssh "$SERVER_USER@$SERVER" "chmod +x $REMOTE_BINARY && chown sol:sol $REMOTE_BINARY"
echo "✓ Permissions set"
echo ""

# Step 6: Create/update startup scripts
echo "Creating startup scripts..."
ssh "$SERVER_USER@$SERVER" << 'REMOTE_EOF'
# VEXOR startup script
cat > /home/sol/validator-vexor.sh << 'VEXOR_SCRIPT'
#!/bin/bash
# VEXOR Validator Startup Script
# Client: VEXOR (Zig-based)

LOG_FILE="/home/sol/logs/vexor.log"

# VEXOR-specific environment variables
export VEXOR_LOG_LEVEL=info
export VEXOR_TILE_THREADS=30

exec /home/sol/vexor/bin/vexor-validator validator \
    --testnet \
    --bootstrap \
    --identity /home/sol/keypairs/validator-keypair.json \
    --vote-account /home/sol/keypairs/vote-account-keypair.json \
    --authorized-voter /home/sol/keypairs/validator-keypair.json \
    --ledger /home/sol/ledger \
    --accounts /home/sol/accounts-ramdisk \
    --log "$LOG_FILE" \
    --public-ip 38.92.24.174 \
    --entrypoint entrypoint.testnet.solana.com:8001 \
    --entrypoint entrypoint2.testnet.solana.com:8001 \
    --entrypoint entrypoint3.testnet.solana.com:8001 \
    --known-validator 5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on \
    --known-validator dDzy5SR3AXdYWVqbDEkVFdvSPCtS9ihF5kJkHCtXoFs \
    --known-validator Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN \
    --known-validator eoKpUABi59aT4rR9HGS3LcMecfut9x7zJyodWWP43YQ \
    --known-validator 9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv \
    --expected-shred-version 9604 \
    --expected-genesis-hash 4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY \
    --rpc-port 8899 \
    --dynamic-port-range 8000-8050 \
    --limit-ledger-size 50000000 \
    --enable-af-xdp \
    --enable-ramdisk \
    --ramdisk-size 64
VEXOR_SCRIPT

chmod +x /home/sol/validator-vexor.sh
chown sol:sol /home/sol/validator-vexor.sh

# Switch client script (if it doesn't exist)
if [ ! -f /home/sol/scripts/switch-client.sh ]; then
    cat > /home/sol/scripts/switch-client.sh << 'SWITCH_SCRIPT'
#!/bin/bash
# Safe Client Switching Script
# Usage: ./switch-client.sh [agave|vexor]

set -e

CLIENT=$1
CURRENT_LINK=$(readlink /home/sol/validator.sh 2>/dev/null || echo "none")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [agave|vexor]"
    echo ""
    echo "Commands:"
    echo "  agave  - Switch to Agave validator client"
    echo "  vexor  - Switch to VEXOR validator client"
    echo "  status - Show current client"
    exit 1
}

show_status() {
    echo -e "${YELLOW}Current Configuration:${NC}"
    echo "  Active script: $CURRENT_LINK"
    
    if systemctl is-active --quiet solana-validator; then
        echo -e "  Service status: ${GREEN}RUNNING${NC}"
        PID=$(pgrep -f "validator" | head -1)
        if [ -n "$PID" ]; then
            BINARY=$(readlink -f /proc/$PID/exe 2>/dev/null || echo "unknown")
            echo "  Running binary: $BINARY"
        fi
    else
        echo -e "  Service status: ${RED}STOPPED${NC}"
    fi
}

switch_to_agave() {
    echo -e "${YELLOW}Switching to Agave...${NC}"
    
    if [ ! -f /home/sol/agave/bin/agave-validator ]; then
        echo -e "${RED}ERROR: Agave binary not found${NC}"
        exit 1
    fi
    
    systemctl stop solana-validator || true
    sleep 5
    
    ln -sf /home/sol/validator-agave.sh /home/sol/validator.sh
    
    systemctl start solana-validator
    
    echo -e "${GREEN}Switched to Agave successfully!${NC}"
}

switch_to_vexor() {
    echo -e "${YELLOW}Switching to VEXOR...${NC}"
    
    if [ ! -f /home/sol/vexor/bin/vexor-validator ]; then
        echo -e "${RED}ERROR: VEXOR binary not found${NC}"
        exit 1
    fi
    
    systemctl stop solana-validator || true
    sleep 5
    
    ln -sf /home/sol/validator-vexor.sh /home/sol/validator.sh
    
    systemctl start solana-validator
    
    echo -e "${GREEN}Switched to VEXOR successfully!${NC}"
}

case "$CLIENT" in
    agave)
        switch_to_agave
        ;;
    vexor)
        switch_to_vexor
        ;;
    status)
        show_status
        ;;
    *)
        show_status
        echo ""
        usage
        ;;
esac
SWITCH_SCRIPT

    chmod +x /home/sol/scripts/switch-client.sh
    chown sol:sol /home/sol/scripts/switch-client.sh
fi
REMOTE_EOF
echo "✓ Startup scripts created"
echo ""

# Step 7: Verify deployment
echo "Verifying deployment..."
ssh "$SERVER_USER@$SERVER" << 'REMOTE_EOF'
echo "Binary:"
ls -lh /home/sol/vexor/bin/vexor-validator
echo ""
echo "Scripts:"
ls -lh /home/sol/validator-vexor.sh
ls -lh /home/sol/scripts/switch-client.sh
REMOTE_EOF

echo ""
echo "=== Deployment Complete! ==="
echo ""
echo "Next steps:"
echo "  1. SSH to server: ssh $SERVER_USER@$SERVER"
echo "  2. Check current status: /home/sol/scripts/switch-client.sh status"
echo "  3. Switch to VEXOR: /home/sol/scripts/switch-client.sh vexor"
echo "  4. Monitor logs: tail -f /home/sol/logs/vexor.log"
echo "  5. If issues, switch back: /home/sol/scripts/switch-client.sh agave"
echo ""
