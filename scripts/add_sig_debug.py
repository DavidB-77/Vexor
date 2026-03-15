with open('src/network/tvu.zig', 'r') as f:
    content = f.read()

# Change 1: Add leader found debug logging
old_code1 = '''if (cache.getSlotLeader(shred_slot)) |leader| {
                if (!shred.verifySignature(&leader)) {'''
new_code1 = '''if (cache.getSlotLeader(shred_slot)) |leader| {
                // DEBUG: Log leader found
                std.debug.print("[SHRED] Leader found for slot {d}\\n", .{shred_slot});
                if (!shred.verifySignature(&leader)) {'''

content = content.replace(old_code1, new_code1)

# Change 2: Remove the "every 1000th" wrapper to log ALL signature failures
old_code2 = '''// DEBUG: Log signature failures (every 1000th to limit spam)
                    if (@mod(count, 1000) == 0) {
                        std.debug.print("[SHRED] Signature FAILED slot={d} idx={d}\\n", .{shred_slot, shred.index()});
                    }'''
new_code2 = '''// DEBUG: Log ALL signature failures
                    std.debug.print("[SHRED] Signature FAILED slot={d} idx={d}\\n", .{shred_slot, shred.index()});'''

content = content.replace(old_code2, new_code2)

with open('src/network/tvu.zig', 'w') as f:
    f.write(content)

print("✅ Added signature debug logging!")
print("  - Added 'Leader found' logging")
print("  - Changed to log ALL signature failures (not just every 1000th)")
