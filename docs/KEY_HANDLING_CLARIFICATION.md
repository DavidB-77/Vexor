# Key Handling & Hot-Swap Clarification

**Date:** December 15, 2024  
**Status:** CLARIFICATION - Awaiting Approval

---

## 🎯 Understanding Your Requirements

### Key Insight: Use Existing Keys from Current Client

**The Goal:**
- When switching to Vexor, use the **SAME keys** that are already working on their current client (Agave, Firedancer, etc.)
- This allows seamless switching without re-staking or downtime
- If something goes wrong, switch back to original client with the same keys
- Optional: Create new keys if they want a separate validator identity

---

## 📋 Revised Key Handling Flow

### Step 1: During Installation

```
┌─────────────────────────────────────────────────────────────┐
│  VEXOR INSTALLER - KEY SELECTION                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Detected Client: Agave (Solana Labs/Anza)                 │
│  Current Keys:                                             │
│    Identity: /home/solana/.secrets/validator-keypair.json │
│    Vote:     /home/solana/.secrets/vote-account-keypair.json│
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ How would you like to handle keys?                    │ │
│  │                                                         │ │
│  │  [1] Use existing keys from Agave (Recommended)       │ │
│  │      → Vexor will use the same keys as Agave          │ │
│  │      → No re-staking needed                           │ │
│  │      → Can switch back to Agave anytime               │ │
│  │                                                         │ │
│  │  [2] Create new keys for Vexor                         │ │
│  │      → Generate new identity and vote keys            │ │
│  │      → Separate validator identity                    │ │
│  │      → Can switch between keys later                  │ │
│  │                                                         │ │
│  │  [3] Use different existing keys                      │ │
│  │      → Specify path to different keypair files        │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  Selection: [1]                                            │
└─────────────────────────────────────────────────────────────┘
```

### Step 2: Key Detection (Automatic)

**What the installer will do:**
1. Detect current client (Agave, Firedancer, Jito, etc.)
2. Detect what keys that client is using:
   - Check service file for `--identity` and `--vote-account` flags
   - Check common key locations:
     - `/home/solana/.secrets/validator-keypair.json`
     - `/home/solana/validator-keypair.json`
     - `/mnt/solana/validator-keypair.json`
     - Check config files (if any)
3. Display detected keys to user
4. Ask: "Use these keys for Vexor?"

### Step 3: Key Usage Options

**Option 1: Use Existing Keys (Recommended)**
- Vexor uses the same keys as current client
- No re-staking needed
- Seamless switching
- Can switch back to original client anytime
- **This is the default/recommended option**

**Option 2: Create New Keys**
- Generate new identity and vote account keypairs
- Separate validator identity
- Requires new stake account setup
- Can switch between keys later via hot-swap

**Option 3: Use Different Existing Keys**
- User specifies path to different keypair files
- Useful if they have multiple validator identities
- Can switch between keys later

### Step 4: Hot-Swap Keys (Later)

**Command:** `vexor-install swap-keys`

```
┌─────────────────────────────────────────────────────────────┐
│  KEY HOT-SWAP                                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Current Keys:                                              │
│    Identity: /home/solana/.secrets/validator-keypair.json │
│    Vote:     /home/solana/.secrets/vote-account-keypair.json│
│                                                             │
│  Available Key Sets:                                         │
│    [1] Original Agave keys (current)                       │
│    [2] New Vexor keys (created during install)              │
│    [3] Custom keys (specify path)                           │
│                                                             │
│  Select keys to use: [1]                                    │
│                                                             │
│  ⚠️  This will:                                             │
│     • Backup current keys                                   │
│     • Switch to selected keys                               │
│     • Restart Vexor (if running)                           │
│                                                             │
│  Continue? [Y/n]                                            │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔧 Implementation Details

### What "Verification" Actually Means

**NOT:** Validating that keys are "new" or "correct"  
**INSTEAD:**
1. **Detect existing keys** from current client
2. **Verify keys are accessible** (file exists, readable)
3. **Verify keys are valid** (can read pubkey from them)
4. **Backup keys** before any changes
5. **Use same keys** for Vexor

### Key Detection Logic

```zig
// Detect keys from current client
fn detectCurrentClientKeys(allocator: Allocator) !ClientKeys {
    // 1. Detect current client
    const client = try detectValidatorClient(allocator);
    
    // 2. Check service file for key paths
    const service_file = try getServiceFile(client);
    const identity_path = try extractKeyPath(service_file, "--identity");
    const vote_path = try extractKeyPath(service_file, "--vote-account");
    
    // 3. Verify keys exist and are readable
    if (identity_path) |id_path| {
        if (try verifyKeyFile(id_path)) {
            return ClientKeys{
                .identity = id_path,
                .vote_account = vote_path,
                .source_client = client,
            };
        }
    }
    
    // 4. Check common locations
    const common_paths = [_][]const u8{
        "/home/solana/.secrets/validator-keypair.json",
        "/home/solana/validator-keypair.json",
        "/mnt/solana/validator-keypair.json",
    };
    
    for (common_paths) |path| {
        if (try verifyKeyFile(path)) {
            return ClientKeys{
                .identity = path,
                .vote_account = null, // Try to find vote account
                .source_client = client,
            };
        }
    }
    
    return error.KeysNotFound;
}
```

### Key Selection During Install

```zig
// In installer.zig cmdInstall()
fn promptForKeySelection(self: *Self, detected_keys: ClientKeys) !KeySelection {
    self.print("\n");
    self.printBanner("KEY SELECTION");
    
    self.print("\n  Detected Client: {s}\n", .{detected_keys.source_client.displayName()});
    self.print("  Current Keys:\n", .{});
    self.print("    Identity: {s}\n", .{detected_keys.identity});
    if (detected_keys.vote_account) |vote| {
        self.print("    Vote:     {s}\n", .{vote});
    }
    
    self.print("\n  How would you like to handle keys?\n", .{});
    self.print("    [1] Use existing keys from {s} (Recommended)\n", .{detected_keys.source_client.displayName()});
    self.print("    [2] Create new keys for Vexor\n", .{});
    self.print("    [3] Use different existing keys\n", .{});
    
    const choice = try self.promptChoice("Selection [1-3]", .{ .default = "1" });
    
    return switch (choice) {
        "1" => .{ .use_existing = detected_keys },
        "2" => .{ .create_new = {} },
        "3" => .{ .use_custom = try self.promptCustomKeys() },
        else => error.InvalidChoice,
    };
}
```

### Hot-Swap Keys Command

```zig
// New command: swap-keys
fn cmdSwapKeys(self: *Self) !void {
    self.printBanner("KEY HOT-SWAP");
    
    // 1. Show current keys
    const current_keys = try getCurrentVexorKeys();
    self.print("\n  Current Keys:\n", .{});
    self.print("    Identity: {s}\n", .{current_keys.identity});
    if (current_keys.vote_account) |vote| {
        self.print("    Vote:     {s}\n", .{vote});
    }
    
    // 2. Show available key sets
    const available_keys = try listAvailableKeySets(self.allocator);
    self.print("\n  Available Key Sets:\n", .{});
    for (available_keys.items, 1..) |key_set, i| {
        self.print("    [{d}] {s}\n", .{ i, key_set.name });
        self.print("        Identity: {s}\n", .{key_set.identity});
    }
    
    // 3. Prompt for selection
    const choice = try self.promptChoice("Select keys to use", .{});
    
    // 4. Backup current keys
    const backup_id = try backupCurrentKeys(self.allocator);
    
    // 5. Switch to selected keys
    try switchToKeys(selected_keys);
    
    // 6. Restart Vexor (if running)
    if (try isVexorRunning()) {
        try restartVexor();
    }
    
    self.print("\n✅ Keys swapped successfully!\n", .{});
    self.print("   Backup ID: {s}\n", .{backup_id});
    self.print("   Rollback: vexor-install swap-keys --restore {s}\n", .{backup_id});
}
```

---

## ✅ Revised Implementation Plan

### What I'll Implement:

1. **Key Detection** ✅
   - Detect current client
   - Detect keys from current client
   - Verify keys are accessible and valid
   - Display detected keys to user

2. **Key Selection During Install** ✅
   - Prompt: "Use existing keys from [client]?" (default: YES)
   - Option: Create new keys
   - Option: Use different existing keys
   - Store selection for later reference

3. **Key Hot-Swap Command** ✅
   - `vexor-install swap-keys` - Switch between key sets
   - List available key sets (original client keys, new keys, custom keys)
   - Backup current keys before swap
   - Switch to selected keys
   - Restart Vexor if running
   - Rollback capability

4. **Key Management** ✅
   - Track which keys are from which client
   - Store key metadata (source, backup location)
   - Easy switching between key sets
   - Automatic backup before any key changes

---

## 🎯 Key Points

1. **Default:** Use existing keys from current client (no re-staking)
2. **Optional:** Create new keys if they want separate identity
3. **Hot-Swap:** Can switch between keys anytime
4. **Safety:** Always backup before key changes
5. **Seamless:** Can switch back to original client with same keys

---

## ❓ Confirmation

**Do I understand correctly?**

1. ✅ Detect current client's keys automatically
2. ✅ Ask during install: "Use existing keys from [client]?" (default: YES)
3. ✅ Option to create new keys if they want
4. ✅ Hot-swap command to switch between keys later
5. ✅ Use same keys = seamless switching, no re-staking
6. ✅ Can switch back to original client with same keys

**If this is correct, I'll proceed with implementation!**

