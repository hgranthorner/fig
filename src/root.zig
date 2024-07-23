const std = @import("std");
const parser = @import("parser.zig");
const testing = std.testing;

test "test all" {
    testing.refAllDecls(@This());
}
