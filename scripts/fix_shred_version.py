with open('src/network/tvu.zig', 'r') as f:
    content = f.read()

# Fix the shred assembler initialization
old_code = '.shred_assembler = try runtime.ShredAssembler.init(allocator),'
new_code = '.shred_assembler = try runtime.ShredAssembler.initWithShredVersion(allocator, config.shred_version),'

content = content.replace(old_code, new_code)

with open('src/network/tvu.zig', 'w') as f:
    f.write(content)

print("✅ Fixed! Shred assembler now uses config.shred_version")
