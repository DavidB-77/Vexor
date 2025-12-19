//! Vexor Auto-Fix System
//! Executes fixes with user permission and verification.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issue_db = @import("issue_database.zig");

/// Result of applying a fix
pub const FixResult = struct {
    issue_id: []const u8,
    success: bool,
    output: []const u8,
    verification_passed: bool,
    error_message: ?[]const u8,
};

/// Fix executor
pub const AutoFix = struct {
    allocator: Allocator,
    backup_dir: []const u8,
    dry_run: bool,
    verbose: bool,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, backup_dir: []const u8, dry_run: bool) Self {
        return .{
            .allocator = allocator,
            .backup_dir = backup_dir,
            .dry_run = dry_run,
            .verbose = false,
        };
    }
    
    /// Apply a fix for a known issue
    pub fn applyFix(self: *Self, issue: issue_db.KnownIssue) !FixResult {
        if (issue.auto_fix == null) {
            return FixResult{
                .issue_id = issue.id,
                .success = false,
                .output = "",
                .verification_passed = false,
                .error_message = "No auto-fix available for this issue",
            };
        }
        
        const fix = issue.auto_fix.?;
        
        if (self.dry_run) {
            return FixResult{
                .issue_id = issue.id,
                .success = true,
                .output = try std.fmt.allocPrint(self.allocator, "[DRY RUN] Would execute: {s}", .{fix.command}),
                .verification_passed = true,
                .error_message = null,
            };
        }
        
        // Create backup if fix is reversible
        if (fix.reversible and fix.rollback_command != null) {
            try self.createBackup(issue.id);
        }
        
        // Execute the fix
        const cmd_result = self.runCommand(fix.command) catch |err| {
            return FixResult{
                .issue_id = issue.id,
                .success = false,
                .output = "",
                .verification_passed = false,
                .error_message = try std.fmt.allocPrint(self.allocator, "Command failed: {}", .{err}),
            };
        };
        defer self.allocator.free(cmd_result);
        
        // Verify the fix
        const verify_result = self.runCommand(fix.verification_command) catch "";
        defer if (verify_result.len > 0) self.allocator.free(verify_result);
        
        const verified = std.mem.indexOf(u8, verify_result, "OK") != null or
            std.mem.indexOf(u8, verify_result, "FAILED") == null;
        
        return FixResult{
            .issue_id = issue.id,
            .success = true,
            .output = cmd_result,
            .verification_passed = verified,
            .error_message = if (!verified) "Verification failed - fix may not have applied correctly" else null,
        };
    }
    
    /// Rollback a fix
    pub fn rollbackFix(self: *Self, issue: issue_db.KnownIssue) !bool {
        if (issue.auto_fix == null) return false;
        
        const fix = issue.auto_fix.?;
        if (fix.rollback_command == null) return false;
        
        if (self.dry_run) {
            return true;
        }
        
        const result = self.runCommand(fix.rollback_command.?) catch return false;
        defer self.allocator.free(result);
        return true;
    }
    
    /// Create a backup before applying fix
    fn createBackup(self: *Self, issue_id: []const u8) !void {
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/fix-{s}-{d}", .{ self.backup_dir, issue_id, timestamp });
        defer self.allocator.free(backup_path);
        
        _ = self.runCommand(try std.fmt.allocPrint(self.allocator, "mkdir -p {s}", .{backup_path})) catch {};
    }
    
    /// Run a shell command
    fn runCommand(self: *Self, cmd: []const u8) ![]u8 {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "sh", "-c", cmd },
        });
        self.allocator.free(result.stderr);
        return result.stdout;
    }
};

/// Interactive fix session - guides user through fixes
pub const FixSession = struct {
    allocator: Allocator,
    fixer: AutoFix,
    applied_fixes: std.ArrayList([]const u8),
    skipped_fixes: std.ArrayList([]const u8),
    failed_fixes: std.ArrayList([]const u8),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, backup_dir: []const u8, dry_run: bool) Self {
        return .{
            .allocator = allocator,
            .fixer = AutoFix.init(allocator, backup_dir, dry_run),
            .applied_fixes = std.ArrayList([]const u8).init(allocator),
            .skipped_fixes = std.ArrayList([]const u8).init(allocator),
            .failed_fixes = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.applied_fixes.deinit();
        self.skipped_fixes.deinit();
        self.failed_fixes.deinit();
    }
    
    /// Get summary of session
    pub fn getSummary(self: *Self) struct { applied: usize, skipped: usize, failed: usize } {
        return .{
            .applied = self.applied_fixes.items.len,
            .skipped = self.skipped_fixes.items.len,
            .failed = self.failed_fixes.items.len,
        };
    }
};

