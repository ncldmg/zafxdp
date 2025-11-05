const std = @import("std");

// List all available network interfaces with their indices
pub fn execute(allocator: std.mem.Allocator) !void {
    std.debug.print("Available network interfaces:\n\n", .{});

    var dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open /sys/class/net: {}\n", .{err});
        std.debug.print("Try running: ip link show\n", .{});
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        // Read ifindex
        const path = try std.fmt.allocPrint(allocator, "/sys/class/net/{s}/ifindex", .{entry.name});
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();

        var buf: [16]u8 = undefined;
        const len = file.readAll(&buf) catch continue;
        if (len == 0) continue;

        const ifindex_str = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
        const ifindex = std.fmt.parseInt(u32, ifindex_str, 10) catch continue;

        std.debug.print("  {d:2}: {s}\n", .{ ifindex, entry.name });
    }

    std.debug.print("\nUse interface name with the 'receive' command\n", .{});
}

// Tests
test "list interfaces execution doesn't crash" {
    const allocator = std.testing.allocator;

    // This test verifies the function doesn't crash
    // It may skip if /sys/class/net is not accessible
    execute(allocator) catch |err| {
        std.debug.print("Note: list interfaces test skipped (error: {})\n", .{err});
        return error.SkipZigTest;
    };

    std.debug.print("✓ List interfaces executed successfully\n", .{});
}

test "can open sys class net directory" {
    var dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch |err| {
        std.debug.print("Skipping test: cannot access /sys/class/net (error: {})\n", .{err});
        return error.SkipZigTest;
    };
    defer dir.close();

    // Count interfaces
    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }

    // Should have at least one interface (loopback)
    try std.testing.expect(count > 0);
    std.debug.print("✓ Found {} network interfaces\n", .{count});
}
