const std = @import("std");
const p = @import("../parser.zig");

const JsonValue = union(enum) {
    null,
    string: []const u8,
    number: u32,
    bool: bool,
    array: std.ArrayList(@This()),
    object: std.StringHashMap(@This()),
};

const JsonParser = p.Parser(JsonValue);
const ParseJsonResult = p.ParseResult(JsonValue);
const JsonRunner = p.Run(JsonValue);

const JsonNull = p.StringParser.init(p.string("null")).map(JsonValue, jsonNull);

fn JsonNumber(alloc: std.mem.Allocator) JsonParser {
    const runner = struct {
        fn run(s: []const u8) !JsonValue {
            defer alloc.free(s);
            const val = try std.fmt.parseInt(u32, s, 0);
            return .{ .number = val };
        }
    };
    const parser = p.StringParser.init(p.parseWhile(alloc, std.ascii.isDigit));
    return parser.except(JsonValue, runner.run);
}

fn JsonString(_: std.mem.Allocator) JsonParser {
    unreachable;
}

const TrueParser = p.StringParser.init(p.string("true"));
const FalseParser = p.StringParser.init(p.string("false"));

const WhitespaceIgnorer = p.Parser(void).init(p.ignoreWhile(std.ascii.isWhitespace));
const CommaIgnorer = p.Parser(void).init(p.ignoreChar(','));

fn JsonArray(alloc: std.mem.Allocator) JsonParser {
    const runner = struct {
        fn run(s: []const u8) !JsonValue {
            defer alloc.free(s);
            const val = try std.fmt.parseInt(u32, s, 0);
            return .{ .number = val };
        }
    };
    const parser = p.Parser(u8).init(p.char('['))
        .ignored(WhitespaceIgnorer)
        .ignored(JsonValueParser(alloc).ignore(WhitespaceIgnorer).ignore(CommaIgnorer).many(alloc))
        .ignore(WhitespaceIgnorer)
        .ignore(p.Parser(u8).init(p.char(']')));
    return parser.except(JsonValue, runner.run);
}

fn JsonObject(_: std.mem.Allocator) JsonParser {
    unreachable;
}

fn jsonBoolFromString(s: []const u8) JsonValue {
    if (std.mem.eql(u8, s, "true")) {
        return .{ .bool = true };
    } else {
        return .{ .bool = false };
    }
}

const JsonBool = TrueParser.alternative(FalseParser).map(jsonBoolFromString);

fn JsonValueParser(alloc: std.mem.allocator) JsonParser {
    return JsonNull
        .alternative(JsonBool)
        .alternative(JsonNumber(alloc))
        .alternative(JsonString(alloc))
        .alternative(JsonArray(alloc))
        .alternative(JsonObject(alloc));
}

fn jsonNull(_: []const u8) JsonValue {
    return .null;
}

const t = std.testing;

test {
    try t.expect(true);
}

test "can parse null" {
    const result = JsonNull.run(p.Input.init("null"));
    switch (result.value) {
        .err => try t.expect(false),
        .value => |val| {
            try t.expectEqual(.null, val);
        },
    }
}

test "can parse number" {
    const result = JsonNumber(t.allocator).run(p.Input.init("1234 5678"));
    try t.expectEqualStrings(" 5678", result.remaining.text);
    switch (result.value) {
        .err => try t.expect(false),
        .value => |val| {
            try t.expectEqual(JsonValue{ .number = 1234 }, val);
        },
    }
}
