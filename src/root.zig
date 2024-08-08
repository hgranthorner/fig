const std = @import("std");
pub const parser = @import("parser.zig");
const testing = std.testing;

test "test all" {
    testing.refAllDecls(@This());
}
