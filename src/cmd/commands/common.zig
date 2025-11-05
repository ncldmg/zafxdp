const std = @import("std");

// Get interface index by name from /sys/class/net
pub fn getIfIndexByName(ifname: []const u8) !u32 {
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "/sys/class/net/{s}/ifindex", .{ifname});
    defer std.heap.page_allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        std.debug.print("Failed to find interface '{s}': {}\n", .{ ifname, err });
        std.debug.print("Run 'zafxdp list-interfaces' to see available interfaces\n", .{});
        return err;
    };
    defer file.close();

    var buf: [16]u8 = undefined;
    const len = try file.readAll(&buf);
    const ifindex_str = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
    return try std.fmt.parseInt(u32, ifindex_str, 10);
}

// Tests
test "getIfIndexByName with loopback interface" {
    // Loopback interface should always exist
    const ifindex = getIfIndexByName("lo") catch |err| {
        // If it fails, it's likely a permission or system issue
        std.debug.print("Skipping test: cannot read /sys/class/net (error: {})\n", .{err});
        return error.SkipZigTest;
    };

    // Loopback interface index is typically 1, but could vary
    try std.testing.expect(ifindex > 0);
    std.debug.print("✓ Found loopback interface with index: {}\n", .{ifindex});
}

test "getIfIndexByName with non-existent interface" {
    // This should fail
    const result = getIfIndexByName("nonexistent_interface_xyz123");
    try std.testing.expectError(error.FileNotFound, result);
    std.debug.print("✓ Correctly failed to find non-existent interface\n", .{});
}
