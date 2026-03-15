test "bank writability enforcement" {
    const allocator = std.testing.allocator;

    // Create accounts DB
    var accounts_db = try storage.AccountsDb.init(allocator, "./test_ledger_writability");
    defer {
        accounts_db.deinit();
        std.fs.cwd().deleteTree("./test_ledger_writability") catch {};
    }

    // Create bank
    var bank = try Bank.init(allocator, &accounts_db, 0, null);
    defer bank.deinit();

    // Create source account with lamports
    const source_pubkey = core.Pubkey.init([_]u8{1} ** 32);
    const source_account = storage.accounts.Account{
        .lamports = 1000,
        .data = &[_]u8{},
        .owner = NATIVE_PROGRAMS.SYSTEM_PUBKEY, // Helper needed or use literal
        .executable = false,
        .rent_epoch = 0,
    };
    try accounts_db.storeAccount(&source_pubkey, &source_account, 0);

    // Create dest account
    const dest_pubkey = core.Pubkey.init([_]u8{2} ** 32);

    // Create instruction to transfer lamports
    // System Transfer: [u32 type=2] [u64 lamports]
    var ix_data = [_]u8{0} ** 12;
    std.mem.writeInt(u32, ix_data[0..4], 2, .little); // Transfer
    std.mem.writeInt(u64, ix_data[4..12], 100, .little); // 100 lamports

    const ix = Instruction{
        .program_id_index = 2, // Map to system program in account_keys
        .account_indices = &[_]u8{ 0, 1 }, // source, dest
        .data = &ix_data,
    };

    // Case 1: Writable Source (Should Succeed)
    {
        const account_keys = [_]core.Pubkey{
            source_pubkey,
            dest_pubkey,
            core.Pubkey{ .data = NATIVE_PROGRAMS.SYSTEM },
        };
        const writability = [_]bool{ true, true, false }; // Source writable, Dest writable

        const tx = Transaction{
            .fee_payer = source_pubkey,
            .signatures = &[_]core.Signature{core.Signature.ZERO},
            .signature_count = 1,
            .signatures_verified = true,
            .message = &[_]u8{},
            .recent_blockhash = core.Hash.ZERO,
            .compute_unit_limit = 10000,
            .compute_unit_price = 0,
            .account_keys = &account_keys,
            .account_writability = &writability,
            .instructions = &[_]Instruction{ix},
        };

        const result = bank.processTransaction(&tx);
        try std.testing.expectEqual(true, result.success);
        try std.testing.expectEqual(null, result.error_code);
    }

    // Case 2: Read-Only Source (Should Fail)
    {
        const account_keys = [_]core.Pubkey{
            source_pubkey,
            dest_pubkey,
            core.Pubkey{ .data = NATIVE_PROGRAMS.SYSTEM },
        };
        const writability = [_]bool{ false, true, false }; // Source READ-ONLY

        const tx = Transaction{
            .fee_payer = source_pubkey,
            .signatures = &[_]core.Signature{core.Signature.ZERO},
            .signature_count = 1,
            .signatures_verified = true,
            .message = &[_]u8{},
            .recent_blockhash = core.Hash.ZERO,
            .compute_unit_limit = 10000,
            .compute_unit_price = 0,
            .account_keys = &account_keys,
            .account_writability = &writability,
            .instructions = &[_]Instruction{ix},
        };

        const result = bank.processTransaction(&tx);
        try std.testing.expectEqual(false, result.success);
        try std.testing.expectEqual(TransactionError.ReadOnlyAccountModification, result.error_code.?);
    }
}
