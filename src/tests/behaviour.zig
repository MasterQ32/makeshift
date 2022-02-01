const std = @import("std");
const mott = @import("../main.zig");

fn expectError(source: []const u8, comptime errors: []const []const u8) !void {
    var diangostics = mott.Diagnostics.init(std.testing.allocator);
    defer diangostics.deinit();

    var ast = try mott.Parser.parse(std.testing.allocator, source, null);
    defer ast.deinit();

    var env = try mott.SemanticAnalysis.check(std.testing.allocator, &diangostics, ast);
    defer env.deinit();

    try std.testing.expectEqual(errors.len, diangostics.errors.items.len);
    for (errors) |err, i| {
        try std.testing.expectEqualStrings(err, diangostics.errors.items[i].message);
    }
}

fn compileExpectNoError(source: []const u8) !void {
    var diangostics = mott.Diagnostics.init(std.testing.allocator);
    defer diangostics.deinit();

    var ast = try mott.Parser.parse(std.testing.allocator, source, null);
    defer ast.deinit();

    var env = try mott.SemanticAnalysis.check(std.testing.allocator, &diangostics, ast);
    defer env.deinit();

    try std.testing.expectEqual(@as(usize, 0), diangostics.errors.items.len);
}

fn runExpectNoError(source: []const u8) !void {
    var diangostics = mott.Diagnostics.init(std.testing.allocator);
    defer diangostics.deinit();

    var ast = try mott.Parser.parse(std.testing.allocator, source, null);
    defer ast.deinit();

    var env = try mott.SemanticAnalysis.check(std.testing.allocator, &diangostics, ast);
    defer env.deinit();

    try std.testing.expectEqual(@as(usize, 0), diangostics.errors.items.len);

    var interpreter = mott.Interpreter.init(std.testing.allocator, &env, ast);
    try interpreter.run();
}

test "initialize variable" {
    try compileExpectNoError(
        \\var x = 1;
        \\fn main() {}
    );
}

test "initialize variable with backref" {
    try compileExpectNoError(
        \\const x = 1337;
        \\const y = x;
    );
}

test "comptime invocation variable with backref" {
    try compileExpectNoError(
        \\fn add(a, b) {
        \\  return a + b;
        \\}
        \\const ten = 10;
        \\const twen = 20;
        \\const comptime = add(ten, twen);
    );
}

test "storing local variables must work at comptime" {
    try compileExpectNoError(
        \\fn storeLocal(a) {
        \\  var b = a + 1;
        \\  return b - 1;
        \\}
        \\const stored_local = storeLocal(3);
    );
}

test "successful detection of indirect runtime data read" {
    try expectError(
        \\var foo;
        \\var addr_of_foo = &foo;
        \\fn storeGlobal(a) {
        \\  addr_of_foo[0] = a;
        \\}
        \\const side_effect = storeGlobal(10);
    , &.{"Cannot evaluate constant expression. Read from runtime data."});
}

test "successful detection of indirection runtime data write" {
    try expectError(
        \\var foo;
        \\var addr_of_foo = &foo;
        \\fn storeGlobal(a) {
        \\  (&addr_of_foo)[0] = a;
        \\}
        \\const side_effect = storeGlobal(10);
    , &.{"Cannot evaluate constant expression. Write to runtime data."});
}

test "indirect calling" {
    try expectError(
        \\fn foo(a) {
        \\  return 2 * a;
        \\}
        \\const foo_ref = foo;
        \\const res = foo_ref(1);
    , &.{"The callee `foo_ref` is not a function. This might be a mistake."});
}
