const std = @import("std");

const ParseErrorTag = union(enum) {
    FailedToMatch: void,
    IndexOutOfBounds: usize,
    ManyFailedToAllocate: std.mem.Allocator.Error,
    Other: anyerror,
};

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

pub fn Run(T: type) type {
    return fn (Input) ParseResult(T);
}

pub fn Runner(T: type) type {
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

pub fn ParseResult(T: type) type {
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

        pub fn is_ok(self: @This()) bool {
            return switch (self.value) {
                .err => false,
                .value => true,
            };
        }

        pub fn is_err(self: @This()) bool {
            return switch (self.value) {
                .err => true,
                .value => false,
            };
        }

        pub fn map(self: @This(), U: type, f: fn (T) U) ParseResult(U) {
            return switch (self.value) {
                .err => |erro| ParseResult(U).init(self.remaining, .{ .err = erro }),
                .value => |val| ParseResult(U).ok(self.remaining, f(val)),
            };
        }

        pub fn except(self: @This(), U: type, f: fn (T) anyerror!U) ParseResult(U) {
            return switch (self.value) {
                .err => |erro| ParseResult(U).init(self.remaining, .{ .err = erro }),
                .value => |val| {
                    const result = f(val) catch |erro| {
                        return ParseResult(U).err(self.remaining, .{ .Other = erro });
                    };
                    return ParseResult(U).ok(self.remaining, result);
                },
            };
        }
    };
}

pub fn Parser(T: type) type {
    return struct {
        const Self = @This();

        run: fn (Input) ParseResult(T),

        pub fn init(run: Run(T)) Self {
            return .{
                .run = run,
            };
        }

        pub fn map(self: Self, U: type, f: fn (T) U) Parser(U) {
            const runner = struct {
                pub fn run(input: Input) ParseResult(U) {
                    const result = self.run(input);
                    return result.map(U, f);
                }
            };

            return Parser(U).init(runner.run);
        }

        pub fn except(self: Self, U: type, f: fn (T) anyerror!U) Parser(U) {
            const runner = struct {
                fn run(input: Input) ParseResult(U) {
                    const result = self.run(input);
                    return switch (result.value) {
                        .err => |err| ParseResult(U).err(result.remaining, err),
                        .value => |val| {
                            const final = f(val) catch |err| {
                                return ParseResult(U).err(
                                    result.remaining,
                                    .{
                                        .description = "Something went wrong!",
                                        .tag = .{ .Other = err },
                                    },
                                );
                            };

                            return ParseResult(U).ok(result.remaining, final);
                        },
                    };
                }
            };

            return Parser(U).init(runner.run);
        }

        pub fn apply(self: Self, U: type, f: fn (ParseResult(T)) ParseResult(U)) Parser(U) {
            const runner = struct {
                pub fn run(input: Input) ParseResult(U) {
                    const result = self.run(input);
                    return switch (result.value) {
                        .err => |err| ParseResult(U).err(result.remaining, err),
                        .value => |val| f(val),
                    };
                }
            };

            return Parser(U).init(runner.run);
        }

        pub fn ignore(self: Self, other: anytype) Self {
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

        pub fn ignored(self: Self, U: type, other: Parser(U)) Parser(U) {
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

        pub fn keep(self: Self, U: type, other: Parser(U)) Parser(std.meta.Tuple(&[_]type{ T, U })) {
            const Tuple = std.meta.Tuple(&[_]type{ T, U });
            const runner = struct {
                const Result = ParseResult(Tuple);
                pub fn run(input: Input) Result {
                    const result = self.run(input);
                    return switch (result.value) {
                        .err => |parse_err| Result.err(input, parse_err),
                        .value => |val| {
                            const other_result = other.run(result.remaining);
                            return switch (other_result.value) {
                                .err => |parse_err| Result.err(result.remaining, parse_err),
                                .value => |other_val| Result.ok(other_result.remaining, .{ val, other_val }),
                            };
                        },
                    };
                }
            };

            return Parser(Tuple).init(runner.run);
        }

        pub fn alternative(self: Self, other: Self) Self {
            const runner = struct {
                pub fn run(input: Input) ParseResult(T) {
                    const result = self.run(input);
                    return switch (result.value) {
                        .value => result,
                        .err => other.run(input),
                    };
                }
            };

            return Self.init(runner.run);
        }

        pub fn many(self: Self, alloc: std.mem.Allocator) Parser(std.ArrayList(T)) {
            const Result = ParseResult(std.ArrayList(T));
            const runner = struct {
                pub fn run(input: Input) Result {
                    var out: std.ArrayList(T) = std.ArrayList(T).init(alloc);
                    var result = self.run(input);
                    while (result.is_ok()) : (result = self.run(result.remaining)) {
                        switch (result.value) {
                            // Unreachable due to the check above
                            .err => unreachable,
                            .value => |val| {
                                out.append(val) catch |err| {
                                    out.deinit();
                                    return Result.err(input, .{
                                        .description = "Failed to allocate during `many`!",
                                        .tag = .{ .ManyFailedToAllocate = err },
                                    });
                                };
                            },
                        }
                    }

                    return Result.ok(result.remaining, out);
                }
            };

            return Parser(std.ArrayList(T)).init(runner.run);
        }
    };
}

pub const ParseStringResult = ParseResult([]const u8);
pub const ParseVoidResult = ParseResult(void);
pub const StringParser = Parser([]const u8);

pub fn identity(input: Input) ParseStringResult {
    return ParseStringResult.ok(input, "");
}

pub fn all(input: Input) ParseStringResult {
    return ParseStringResult.ok(
        .{ .text = "", .pos = @intCast(input.text.len) },
        input.text,
    );
}

pub fn string(str: []const u8) Run([]const u8) {
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
                    .tag = ParseErrorTag.FailedToMatch,
                });
            }
        }
    };
    return runner.run;
}

pub fn ignoreChar(c: u8) Run(void) {
    const runner = struct {
        fn run(input: Input) ParseVoidResult {
            if (input.text.len > 0 and input.text[0] == c) {
                return ParseVoidResult.ok(
                    Input{
                        .pos = input.pos + 1,
                        .text = input.text[1..],
                    },
                    void,
                );
            } else {
                return ParseVoidResult.err(
                    input,
                    .{
                        .description = "Char did not match",
                        .tag = ParseErrorTag.FailedToMatch,
                    },
                );
            }
        }
    };

    return runner.run;
}

pub fn ignoreWhile(f: fn (u8) bool) Run(void) {
    const runner = struct {
        fn run(input: Input) ParseVoidResult {
            var i = input;

            while (i.text.len > 0 and f(i.text[0])) {
                i = Input{
                    .pos = i.pos + 1,
                    .text = i.text[1..],
                };
            }

            return ParseStringResult.ok(i, void);
        }
    };
    return runner.run;
}

pub fn parseWhile(alloc: std.mem.Allocator, f: fn (u8) bool) Run([]const u8) {
    const runner = struct {
        fn run(input: Input) ParseStringResult {
            var buf = std.ArrayList(u8).init(alloc);
            var i = input;

            while (i.text.len > 0 and f(i.text[0])) {
                buf.append(i.text[0]) catch |err| {
                    buf.deinit();
                    return ParseStringResult.err(input, .{
                        .description = "Failed to allocate during `parseWhile`!",
                        .tag = .{ .ManyFailedToAllocate = err },
                    });
                };

                i = Input{
                    .pos = i.pos + 1,
                    .text = i.text[1..],
                };
            }

            const s = buf.toOwnedSlice() catch |err| {
                buf.deinit();
                return ParseStringResult.err(input, .{
                    .description = "Failed to allocate during `parseWhile`!",
                    .tag = .{ .ManyFailedToAllocate = err },
                });
            };

            return ParseStringResult.ok(i, s);
        }
    };
    return runner.run;
}

pub fn char(c: u8) Run(u8) {
    const Result = ParseResult(u8);
    const runner = struct {
        fn run(input: Input) Result {
            if (input.text.len < 0) {
                return Result.err(input, .{
                    .description = "No more input left to read",
                    .tag = .IndexOutOfBounds(0),
                });
            } else if (input.text[0] == c) {
                return Result.ok(
                    .{ .pos = input.pos + 1, .text = input.text[1..] },
                    c,
                );
            } else {
                return Result.err(input, .{
                    .description = "First character did not match",
                    .tag = .FailedToMatch,
                });
            }
        }
    };
    return runner.run;
}

const t = std.testing;

test "Can create and run a parser" {
    const parser = StringParser.init(identity);
    const result = parser.run(Input.init("hello world"));

    switch (result.value) {
        .err => try t.expect(false),
        .value => |val| try t.expectEqualStrings("", val),
    }
}

test "Can map over a parser" {
    const parser = StringParser.init(all);
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
    const parser = StringParser.init(string("hello"));
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
    const parser = StringParser.init(string("hello"));
    const result = parser.run(Input.init("world"));
    try t.expectEqualStrings("world", result.remaining.text);
    try t.expectEqual(0, result.remaining.pos);
    switch (result.value) {
        .value => try t.expect(false),
        .err => |err| {
            try t.expectEqual(ParseErrorTag.FailedToMatch, err.tag);
        },
    }
}

test "ignore" {
    const parser = StringParser.init(string("hello"));
    const other = StringParser.init(string(" world"));
    const result = parser.ignore(other).run(Input.init("hello world"));
    try t.expectEqualStrings("", result.remaining.text);
    switch (result.value) {
        .value => |val| {
            try t.expectEqualStrings("hello", val);
        },
        .err => try t.expect(false),
    }
}

test "ignored" {
    const parser = StringParser.init(string(" "));
    const other = StringParser.init(string("world"));
    const result = parser.ignored([]const u8, other).run(Input.init(" world"));
    try t.expectEqualStrings("", result.remaining.text);
    switch (result.value) {
        .value => |val| {
            try t.expectEqualStrings("world", val);
        },
        .err => try t.expect(false),
    }
}

test "Keep" {
    const parser = StringParser.init(string("hello"));
    const other = StringParser.init(string("world"));
    const applied = parser.keep([]const u8, other);
    const result = applied.run(Input.init("helloworld"));
    try t.expectEqualStrings("", result.remaining.text);
    switch (result.value) {
        .value => |val| {
            try t.expectEqualStrings("hello", val[0]);
            try t.expectEqualStrings("world", val[1]);
        },
        .err => try t.expect(false),
    }
}

test "Altogether now" {
    const hello = StringParser.init(string("hello"));
    const space = StringParser.init(string(" "));
    const world = StringParser.init(string("world"));
    const parser = hello.ignore(space).keep([]const u8, world);
    const result = parser.run(Input.init("hello world"));
    try t.expectEqualStrings("", result.remaining.text);
    switch (result.value) {
        .value => |val| {
            try t.expectEqualStrings("hello", val[0]);
            try t.expectEqualStrings("world", val[1]);
        },
        .err => try t.expect(false),
    }
}

test "Alternative" {
    const hello = StringParser.init(string("hello"));
    const world = StringParser.init(string("world"));
    const result = hello.alternative(world).run(Input.init("world"));
    try t.expectEqualStrings("", result.remaining.text);
    switch (result.value) {
        .value => |val| {
            try t.expectEqualStrings("world", val);
        },
        .err => try t.expect(false),
    }
}

test "Many" {
    const space = Parser(u8).init(char(' '));
    const spaces = space.many(t.allocator);
    const result = spaces.run(Input.init("     abc"));
    try t.expectEqualStrings("abc", result.remaining.text);
    switch (result.value) {
        .err => try t.expect(false),
        .value => |val| {
            defer val.deinit();
            try t.expectEqual(5, val.items.len);
        },
    }
}

test "parseWhile" {
    const digits = Parser([]const u8).init(parseWhile(t.allocator, std.ascii.isDigit));
    const result = digits.run(Input.init("1234 5678"));
    try t.expectEqualStrings(" 5678", result.remaining.text);
    switch (result.value) {
        .err => try t.expect(false),
        .value => |val| {
            defer t.allocator.free(val);
            try t.expectEqualStrings("1234", val);
        },
    }
}
