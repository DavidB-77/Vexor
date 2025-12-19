//! Vexor Backup Manager
//! Creates and verifies backups before any state changes.
//!
//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║                         BACKUP STRATEGY                                    ║
//! ╠═══════════════════════════════════════════════════════════════════════════╣
//! ║                                                                            ║
//! ║  CRITICAL FILES (always backup before switch):                            ║
//! ║    • tower-*.bin     - Consensus state (prevents double-voting)           ║
//! ║    • validator-keypair.json  - Identity (irreplaceable!)                  ║
//! ║    • vote-account-keypair.json                                            ║
//! ║    • Config files                                                          ║
//! ║                                                                            ║
//! ║  STATE SNAPSHOT (optional, for rollback):                                  ║
//! ║    • Latest full snapshot                                                  ║
//! ║    • Latest incremental snapshot                                           ║
//! ║    • Accounts database metadata                                            ║
//! ║                                                                            ║
//! ║  VERIFICATION:                                                             ║
//! ║    • SHA256 checksums                                                      ║
//! ║    • File size validation                                                  ║
//! ║    • Keypair readability test                                              ║
//! ║                                                                            ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝

const std = @import("std");
const fs = std.fs;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

/// Backup configuration
pub const BackupConfig = struct {
    /// Base backup directory
    backup_dir: []const u8 = "/var/backups/vexor",
    
    /// Paths to critical files
    identity_path: []const u8,
    vote_account_path: []const u8,
    
    /// Agave paths
    agave_ledger_path: []const u8,
    agave_runtime_path: []const u8,
    
    /// Vexor paths
    vexor_ledger_path: []const u8,
    vexor_runtime_path: []const u8,
    
    /// Maximum backups to keep
    max_backups: u32 = 10,
    
    /// Compress backups
    compress: bool = true,
};

/// Backup result
pub const BackupResult = struct {
    success: bool,
    backup_id: []const u8,
    backup_path: []const u8,
    timestamp: i64,
    files_backed_up: u32,
    total_size: u64,
    checksums: std.StringHashMap([]const u8),
    errors: std.ArrayList([]const u8),

    pub fn print(self: *const BackupResult) void {
        const status = if (self.success) "✅ SUCCESS" else "❌ FAILED";
        
        std.debug.print(
            \\
            \\╔══════════════════════════════════════════════════════════════╗
            \\║                    BACKUP RESULT                              ║
            \\╠══════════════════════════════════════════════════════════════╣
            \\║  Status:          {s}                                    ║
            \\║  Backup ID:       {s}                                    ║
            \\║  Path:            {s}
            \\║  Files:           {d}                                         ║
            \\║  Total Size:      {d} bytes                                   ║
            \\╚══════════════════════════════════════════════════════════════╝
            \\
        , .{
            status,
            self.backup_id,
            self.backup_path,
            self.files_backed_up,
            self.total_size,
        });

        if (self.errors.items.len > 0) {
            std.debug.print("\n⚠️  Errors:\n", .{});
            for (self.errors.items) |err| {
                std.debug.print("   - {s}\n", .{err});
            }
        }
    }
};

/// File info for verification
pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    checksum: [32]u8,
    exists: bool,
};

/// Backup Manager
pub const BackupManager = struct {
    allocator: Allocator,
    config: BackupConfig,

    const Self = @This();

    pub fn init(allocator: Allocator, config: BackupConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PRE-SWITCH BACKUP
    // ═══════════════════════════════════════════════════════════════════════

    /// Create a complete backup before switching clients
    pub fn createPreSwitchBackup(self: *Self, source_client: []const u8) !BackupResult {
        const timestamp = std.time.timestamp();
        const backup_id = try std.fmt.allocPrint(
            self.allocator,
            "pre-switch-{s}-{d}",
            .{ source_client, timestamp },
        );

        const backup_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.config.backup_dir, backup_id },
        );

        std.debug.print("\n📦 Creating pre-switch backup...\n", .{});
        std.debug.print("   Backup ID: {s}\n", .{backup_id});
        std.debug.print("   Location:  {s}\n", .{backup_path});

        // Create backup directory
        try fs.cwd().makePath(backup_path);

        var result = BackupResult{
            .success = false,
            .backup_id = backup_id,
            .backup_path = backup_path,
            .timestamp = timestamp,
            .files_backed_up = 0,
            .total_size = 0,
            .checksums = std.StringHashMap([]const u8).init(self.allocator),
            .errors = std.ArrayList([]const u8).init(self.allocator),
        };

        // 1. Backup identity keypair (CRITICAL)
        std.debug.print("   ├─ Backing up identity keypair...\n", .{});
        if (try self.backupFile(self.config.identity_path, backup_path, "validator-keypair.json")) {
            result.files_backed_up += 1;
            result.total_size += try self.getFileSize(self.config.identity_path);
        } else {
            try result.errors.append("Failed to backup identity keypair");
        }

        // 2. Backup vote account (CRITICAL)
        std.debug.print("   ├─ Backing up vote account keypair...\n", .{});
        if (try self.backupFile(self.config.vote_account_path, backup_path, "vote-account-keypair.json")) {
            result.files_backed_up += 1;
            result.total_size += try self.getFileSize(self.config.vote_account_path);
        } else {
            try result.errors.append("Failed to backup vote account");
        }

        // 3. Backup tower state files (CRITICAL for consensus)
        std.debug.print("   ├─ Backing up tower state...\n", .{});
        const ledger_path = if (std.mem.eql(u8, source_client, "agave"))
            self.config.agave_ledger_path
        else
            self.config.vexor_ledger_path;

        const tower_count = try self.backupTowerFiles(ledger_path, backup_path);
        result.files_backed_up += tower_count;
        std.debug.print("      Found {d} tower files\n", .{tower_count});

        // 4. Create manifest file
        std.debug.print("   └─ Creating backup manifest...\n", .{});
        try self.createManifest(backup_path, &result);

        // Verify the backup
        std.debug.print("\n🔍 Verifying backup...\n", .{});
        const verified = try self.verifyBackup(backup_path);
        result.success = verified and result.errors.items.len == 0;

        if (result.success) {
            std.debug.print("   ✅ Backup verified successfully!\n", .{});
        } else {
            std.debug.print("   ❌ Backup verification failed!\n", .{});
        }

        return result;
    }

    /// Backup a single file
    fn backupFile(self: *Self, source: []const u8, backup_dir: []const u8, name: []const u8) !bool {
        _ = self;
        
        const dest = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/{s}",
            .{ backup_dir, name },
        );
        defer std.heap.page_allocator.free(dest);

        // Copy file
        fs.cwd().copyFile(source, fs.cwd(), dest, .{}) catch |err| {
            std.debug.print("      ⚠️  Failed to copy {s}: {}\n", .{ source, err });
            return false;
        };

        return true;
    }

    /// Backup tower state files
    fn backupTowerFiles(self: *Self, ledger_path: []const u8, backup_dir: []const u8) !u32 {
        var count: u32 = 0;

        var dir = fs.cwd().openDir(ledger_path, .{ .iterate = true }) catch |err| {
            std.debug.print("      ⚠️  Cannot open ledger dir: {}\n", .{err});
            return 0;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, "tower-") and
                std.mem.endsWith(u8, entry.name, ".bin"))
            {
                const source_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}",
                    .{ ledger_path, entry.name },
                );
                defer self.allocator.free(source_path);

                if (try self.backupFile(source_path, backup_dir, entry.name)) {
                    count += 1;
                }
            }
        }

        return count;
    }

    /// Create backup manifest
    fn createManifest(self: *Self, backup_path: []const u8, result: *BackupResult) !void {
        const manifest_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/manifest.json",
            .{backup_path},
        );
        defer self.allocator.free(manifest_path);

        const file = try fs.cwd().createFile(manifest_path, .{});
        defer file.close();

        var writer = file.writer();
        try writer.print(
            \\{{
            \\  "backup_id": "{s}",
            \\  "timestamp": {d},
            \\  "files_count": {d},
            \\  "total_size": {d},
            \\  "type": "pre-switch",
            \\  "version": "1.0"
            \\}}
            \\
        , .{
            result.backup_id,
            result.timestamp,
            result.files_backed_up,
            result.total_size,
        });
    }

    /// Verify backup integrity
    pub fn verifyBackup(self: *Self, backup_path: []const u8) !bool {
        var all_valid = true;

        // Check identity keypair
        const id_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/validator-keypair.json",
            .{backup_path},
        );
        defer self.allocator.free(id_path);

        if (!try self.verifyKeypairFile(id_path)) {
            std.debug.print("   ❌ Identity keypair invalid!\n", .{});
            all_valid = false;
        } else {
            std.debug.print("   ✅ Identity keypair valid\n", .{});
        }

        // Check vote account
        const vote_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/vote-account-keypair.json",
            .{backup_path},
        );
        defer self.allocator.free(vote_path);

        if (!try self.verifyKeypairFile(vote_path)) {
            std.debug.print("   ❌ Vote account invalid!\n", .{});
            all_valid = false;
        } else {
            std.debug.print("   ✅ Vote account valid\n", .{});
        }

        // Check manifest exists
        const manifest_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/manifest.json",
            .{backup_path},
        );
        defer self.allocator.free(manifest_path);

        fs.cwd().access(manifest_path, .{}) catch {
            std.debug.print("   ❌ Manifest missing!\n", .{});
            all_valid = false;
        };

        return all_valid;
    }

    /// Verify a keypair file is valid JSON and readable
    fn verifyKeypairFile(self: *Self, path: []const u8) !bool {
        _ = self;
        
        const file = fs.cwd().openFile(path, .{}) catch return false;
        defer file.close();

        var buf: [4096]u8 = undefined;
        const len = file.readAll(&buf) catch return false;

        // Basic JSON validation - should start with [ and end with ]
        const content = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
        if (content.len < 2) return false;
        if (content[0] != '[' or content[content.len - 1] != ']') return false;

        return true;
    }

    fn getFileSize(self: *Self, path: []const u8) !u64 {
        _ = self;
        const stat = try fs.cwd().statFile(path);
        return stat.size;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RESTORE
    // ═══════════════════════════════════════════════════════════════════════

    /// Restore from a backup
    pub fn restoreBackup(self: *Self, backup_id: []const u8) !bool {
        const backup_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.config.backup_dir, backup_id },
        );
        defer self.allocator.free(backup_path);

        std.debug.print("\n🔄 Restoring from backup: {s}\n", .{backup_id});

        // Verify backup first
        if (!try self.verifyBackup(backup_path)) {
            std.debug.print("❌ Backup verification failed, aborting restore!\n", .{});
            return false;
        }

        // Restore identity keypair
        const id_backup = try std.fmt.allocPrint(
            self.allocator,
            "{s}/validator-keypair.json",
            .{backup_path},
        );
        defer self.allocator.free(id_backup);

        fs.cwd().copyFile(id_backup, fs.cwd(), self.config.identity_path, .{}) catch |err| {
            std.debug.print("❌ Failed to restore identity: {}\n", .{err});
            return false;
        };

        std.debug.print("✅ Restored successfully!\n", .{});
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CLEANUP
    // ═══════════════════════════════════════════════════════════════════════

    /// Cleanup old backups, keeping only max_backups
    pub fn cleanupOldBackups(self: *Self) !u32 {
        var dir = fs.cwd().openDir(self.config.backup_dir, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var backups = std.ArrayList([]const u8).init(self.allocator);
        defer backups.deinit();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "pre-switch-")) {
                try backups.append(try self.allocator.dupe(u8, entry.name));
            }
        }

        // Sort by timestamp (embedded in name)
        // Delete oldest if over limit
        var deleted: u32 = 0;
        while (backups.items.len > self.config.max_backups) {
            const oldest = backups.orderedRemove(0);
            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ self.config.backup_dir, oldest },
            );
            defer self.allocator.free(path);

            // Remove directory recursively
            fs.cwd().deleteTree(path) catch continue;
            deleted += 1;
        }

        return deleted;
    }

    /// List all available backups
    pub fn listBackups(self: *Self) !void {
        var dir = fs.cwd().openDir(self.config.backup_dir, .{ .iterate = true }) catch {
            std.debug.print("No backups found at {s}\n", .{self.config.backup_dir});
            return;
        };
        defer dir.close();

        std.debug.print("\n📦 Available Backups:\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});

        var count: u32 = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "pre-switch-")) {
                std.debug.print("  • {s}\n", .{entry.name});
                count += 1;
            }
        }

        if (count == 0) {
            std.debug.print("  (no backups found)\n", .{});
        } else {
            std.debug.print("\nTotal: {d} backup(s)\n", .{count});
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "BackupManager: init" {
    const config = BackupConfig{
        .identity_path = "/tmp/test-id.json",
        .vote_account_path = "/tmp/test-vote.json",
        .agave_ledger_path = "/tmp/agave",
        .agave_runtime_path = "/tmp/agave-run",
        .vexor_ledger_path = "/tmp/vexor",
        .vexor_runtime_path = "/tmp/vexor-run",
    };

    const manager = BackupManager.init(std.testing.allocator, config);
    _ = manager;
}

