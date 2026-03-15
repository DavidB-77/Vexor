const std = @import("std");
const shred = @import("runtime/shred.zig");

pub fn main() void {
    const common: shred.ShredCommonHeader = undefined;
    const data: shred.DataShred = undefined;
    _ = common;
    _ = data;
    std.debug.print("ShredCommonHeader size: {d}\n", .{@sizeOf(shred.ShredCommonHeader)});
    std.debug.print("DataShred size: {d}\n", .{@sizeOf(shred.DataShred)});
    std.debug.print("Signature offset: {d}\n", .{@offsetOf(shred.ShredCommonHeader, "signature")});
    std.debug.print("ShredType offset: {d}\n", .{@offsetOf(shred.ShredCommonHeader, "shred_type")});
}
