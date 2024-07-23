const std = @import("std");

const ParseErrorTag = union(enum) { PrefixMismatch };

pub const Input = struct {
    text: []const u8,
    pos: usize,

    pub fn init(text: []const u8) @This() {
        return .{
            .text = text,
            .pos = 0,
        };
    }
};

const ParseError = struct {
    description: []const u8,
    tag: ParseErrorTag,
};

fn Run(T: type) type {
    return fn (Input) ParseResult(T);
}

fn Runner(T: type) type {
    return struct {
        run: Run(T),
    };
}

pub fn ParseValue(T: type) type {
    return union(enum) {
        value: T,
        err: ParseError,
    };
}

fn ParseResult(T: type) type {
    return struct {
        remaining: Input,
        value: ParseValue(T),

        pub fn init(rem: Input, val: ParseValue(T)) @This() {
            return .{
                .remaining = rem,
                .value = val,
            };
        }

        pub fn ok(rem: Input, val: T) @This() {
            return .{
                .remaining = rem,
                .value = .{ .value = val },
            };
        }

        pub fn err(rem: Input, parse_err: ParseError) @This() {
            return .{
                .remaining = rem,
                .value = .{ .err = parse_err },
            };
        }
    };
}
pub fn Parser(T: type) type {
    return struct {
        const Self = @This();

        run: fn (Input) ParseResult(T),

        pub fn init(run: fn (Input) ParseResult(T)) Self {
            return .{
                .run = run,
            };
        }

        pub fn map(self: Self, U: type, f: fn (T) U) Parser(U) {
            const runner = struct {
                pub fn run(input: Input) ParseResult(U) {
                    const result = self.run(input);
                    switch (result.value) {
                        .value => |val| {
                            return ParseResult(U).init(result.remaining, .{ .value = f(val) });
                        },
                        .err => |err| {
                            return ParseResult(U).init(input, .{ .err = err });
                        },
                    }
                }
            };

            return Parser(U).init(runner.run);
        }

        pub fn takeLeft(self: Self, other: anytype) Self {
            const runner = struct {
                pub fn run(input: Input) ParseResult(T) {
                    const result = self.run(input);
                    return switch (result.value) {
                        .err => result,
                        .value => {
                            const other_result = other.run(result.remaining);
                            return switch (other_result.value) {
                                .err => other_result,
                                .value => |_| ParseResult(T).init(other_result.remaining, result.value),
                            };
                        },
                    };
                }
            };

            return Parser(T).init(runner.run);
        }

        pub fn takeRight(self: Self, U: type, other: Parser(U)) Parser(U) {
            const runner = struct {
                pub fn run(input: Input) ParseResult(T) {
                    const result = self.run(input);
                    return switch (result.value) {
                        .err => result,
                        .value => {
                            return other.run(result.remaining);
                        },
                    };
                }
            };

            return Parser(U).init(runner.run);
        }
    };
}

const ParseStringResult = ParseResult([]const u8);

pub fn identity(input: Input) ParseStringResult {
    return ParseStringResult.ok(input, "");
}

pub fn all(input: Input) ParseStringResult {
    return ParseStringResult.ok(
        .{ .text = "", .pos = @intCast(input.text.len) },
        input.text,
    );
}

pub fn prefix(str: []const u8) Runner([]const u8) {
    const runner = struct {
        fn run(input: Input) ParseStringResult {
            if (std.mem.eql(u8, str, input.text[0..str.len])) {
                return ParseStringResult.ok(Input{
                    .text = input.text[str.len..],
                    .pos = input.pos + str.len,
                }, str);
            } else {
                return ParseStringResult.err(input, .{
                    .description = "Prefix did not match",
                    .tag = ParseErrorTag.PrefixMismatch,
                });
            }
        }
    };
    return .{ .run = runner.run };
}

const t = std.testing;

test "Can create and run a parser" {
    const parser = Parser([]const u8).init(identity);
    const result = parser.run(Input.init("hello world"));

    switch (result.value) {
        .err => try t.expect(false),
        .value => |val| try t.expectEqualStrings("", val),
    }
}

test "Can map over a parser" {
    const parser = Parser([]const u8).init(all);
    const mapper = struct {
        pub fn map(text: []const u8) !u32 {
            return std.fmt.parseInt(u32, text, 0);
        }
    };
    const new_parser = parser.map(std.fmt.ParseIntError!u32, mapper.map);
    const result = new_parser.run(Input.init("69"));
    switch (result.value) {
        .err => try t.expect(false),
        .value => |val| try t.expectEqual(69, val),
    }

    const result2 = new_parser.run(Input.init("69a"));
    switch (result2.value) {
        .err => try t.expect(true),
        .value => |val| try t.expectError(std.fmt.ParseIntError.InvalidCharacter, val),
    }
}

test "Prefix" {
    const parser = Parser([]const u8).init(prefix("hello").run);
    const result = parser.run(Input.init("hello world"));
    try t.expectEqualStrings(" world", result.remaining.text);
    try t.expectEqual(5, result.remaining.pos);
    switch (result.value) {
        .value => |val| {
            try t.expectEqualStrings("hello", val);
        },
        .err => try t.expect(false),
    }
}

test "Prefix fails" {
    const parser = Parser([]const u8).init(prefix("hello").run);
    const result = parser.run(Input.init("world"));
    try t.expectEqualStrings("world", result.remaining.text);
    try t.expectEqual(0, result.remaining.pos);
    switch (result.value) {
        .value => try t.expect(false),
        .err => |err| {
            try t.expectEqual(ParseErrorTag.PrefixMismatch, err.tag);
        },
    }
}

test "takeLeft" {
    const parser = Parser([]const u8).init(prefix("hello").run);
    const other = Parser([]const u8).init(prefix(" world").run);
    const result = parser.takeLeft(other).run(Input.init("hello world"));
    try t.expectEqualStrings("", result.remaining.text);
    switch (result.value) {
        .value => |val| {
            try t.expectEqualStrings("hello", val);
        },
        .err => try t.expect(false),
    }
}

test "takeRight" {
    const parser = Parser([]const u8).init(prefix(" ").run);
    const other = Parser([]const u8).init(prefix("world").run);
    const result = parser.takeRight([]const u8, other).run(Input.init(" world"));
    try t.expectEqualStrings("", result.remaining.text);
    switch (result.value) {
        .value => |val| {
            try t.expectEqualStrings("world", val);
        },
        .err => try t.expect(false),
    }
}
