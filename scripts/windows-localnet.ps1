param(
  [string]$LedgerPath = "C:\temp\vexor-localnet",
  [int]$GossipPort = 9001,
  [int]$RpcPort = 8899,
  [string]$DynamicPortRange = "9002-9019",
  [int]$FaucetPort = 9900,
  [string]$BindAddress = "0.0.0.0",
  [string]$GossipHost = "172.17.240.1",
  [int]$LimitLedgerSize = 5000,
  [int]$SlotsPerEpoch = 32,
  [int]$TicksPerSlot = 32,
  [int]$FaucetSol = 500,
[string]$KeypairPath = "C:\Users\David B\.config\solana\id.json"
)

Write-Host "=== VEXOR Localnet Setup (Windows) ==="
Write-Host "Ledger: $LedgerPath"
Write-Host "RPC:    http://127.0.0.1:$RpcPort"
Write-Host "Gossip: ${GossipHost}:$GossipPort"
Write-Host ""

if (!(Test-Path $LedgerPath)) {
  New-Item -ItemType Directory -Force -Path $LedgerPath | Out-Null
}

if (!(Test-Path $KeypairPath)) {
  Write-Host "No keypair found at $KeypairPath"
  Write-Host "Creating one now (follow prompts)..."
  solana-keygen new -o "$KeypairPath"
}

# Resolve short path to avoid space issues with signer parsing
$ResolvedKeypairPath = $KeypairPath
$KeypairItem = Get-Item -LiteralPath $KeypairPath
if ($KeypairItem.ShortName -and $KeypairItem.Directory) {
  $ResolvedKeypairPath = Join-Path $KeypairItem.Directory.FullName $KeypairItem.ShortName
}

& solana-keygen pubkey "$ResolvedKeypairPath" | ForEach-Object {
  $MintPubkey = $_
}
Write-Host "Mint pubkey: $MintPubkey"
Write-Host ""

Write-Host ""
Write-Host "Starting solana-test-validator..."
Write-Host "Press Ctrl+C to stop."
Write-Host ""

solana-test-validator `
  --ledger "$LedgerPath" `
  --reset `
  --gossip-port $GossipPort `
  --rpc-port $RpcPort `
  --dynamic-port-range $DynamicPortRange `
  --faucet-port $FaucetPort `
  --bind-address $BindAddress `
  --gossip-host $GossipHost `
  --mint $MintPubkey `
  --limit-ledger-size $LimitLedgerSize `
  --slots-per-epoch $SlotsPerEpoch `
  --ticks-per-slot $TicksPerSlot `
  --faucet-sol $FaucetSol
