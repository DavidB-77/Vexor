import re

with open('src/network/tvu.zig', 'r') as f:
    content = f.read()

# Edit 1: Add after line with "const count = self.stats.shreds_received"
old_line1 = 'const count = self.stats.shreds_received.fetchAdd(1, .monotonic);'
new_code1 = '''const count = self.stats.shreds_received.fetchAdd(1, .monotonic);
        // DEBUG: Log every shred's type byte and size
        std.debug.print("[SHRED-DEBUG] byte[64]=0x{x:0>2} len={d}\\n", .{if (pkt.payload().len > 64) pkt.payload()[64] else 0, pkt.payload().len});'''

content = content.replace(old_line1, new_code1, 1)

# Edit 2: Modify the Parse FAILED line
old_line2 = 'std.debug.print("[SHRED] Parse FAILED: {s} (count={d}, len={d})\\n", .{@errorName(err), count, pkt.payload().len});'
new_code2 = 'std.debug.print("[SHRED] Parse FAILED: {s} (count={d}, len={d}) type=0x{x:0>2}\\n", .{@errorName(err), count, pkt.payload().len, if (pkt.payload().len > 64) pkt.payload()[64] else 0});'

content = content.replace(old_line2, new_code2, 1)

with open('src/network/tvu.zig', 'w') as f:
    f.write(content)

print("✅ Both edits applied successfully")
