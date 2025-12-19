//! Vexor Installer Module
//! Comprehensive audit-first installation system for Vexor validators.
//!
//! Architecture:
//!   1. Issue Database - Known issues with MASQUE, QUIC, AF_XDP, etc.
//!   2. Auto-Diagnosis - Detects issues on the system
//!   3. Recommendation Engine - Generates personalized recommendations
//!   4. Auto-Fix - Executes fixes with permission

pub const issue_database = @import("issue_database.zig");
pub const auto_diagnosis = @import("auto_diagnosis.zig");
pub const auto_fix = @import("auto_fix.zig");
pub const recommendation_engine = @import("recommendation_engine.zig");

// Re-export key types
pub const KnownIssue = issue_database.KnownIssue;
pub const RiskLevel = issue_database.RiskLevel;
pub const Category = issue_database.Category;
pub const Severity = issue_database.Severity;
pub const AutoFix = issue_database.AutoFix;

pub const AutoDiagnosis = auto_diagnosis.AutoDiagnosis;
pub const DetectedIssue = auto_diagnosis.DetectedIssue;

pub const FixResult = auto_fix.FixResult;
pub const FixSession = auto_fix.FixSession;

pub const RecommendationEngine = recommendation_engine.RecommendationEngine;
pub const Recommendation = recommendation_engine.Recommendation;
pub const Priority = recommendation_engine.Priority;
pub const AuditResults = recommendation_engine.AuditResults;

/// Quick access to all known issues
pub const all_issues = issue_database.all_issues;

/// Find issue by ID
pub const findIssueById = issue_database.findIssueById;

