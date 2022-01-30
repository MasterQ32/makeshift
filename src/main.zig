const std = @import("std");
const ihex = @import("ihex");
const ptk = @import("parser-toolkit");

pub const Diagnostics = ptk.Diagnostics;

pub fn main() anyerror!void {
    const stdout = std.io.getStdOut();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const demo_source = try std.fs.cwd().readFileAlloc(gpa.allocator(), "docs/scratchpad.mott", 1 << 16);
    defer gpa.allocator().free(demo_source);

    var diangostics = ptk.Diagnostics.init(gpa.allocator());
    defer diangostics.deinit();

    defer {
        stdout.writeAll("Diagnostics:\n") catch {};
        diangostics.print(stdout.writer()) catch {};
    }

    var ast = try Parser.parse(gpa.allocator(), demo_source, "docs/scratchpad.mott");
    defer ast.deinit();

    try AstPrinter(std.fs.File.Writer).print(ast, stdout.writer());

    var env = try SemanticAnalysis.check(gpa.allocator(), &diangostics, ast);
    defer env.deinit();

    {
        try stdout.writeAll("symbol tables:\n");

        const mutable_names = [_][]const u8{ "const", "mutable" };

        var iter = env.globals.iterator();
        while (iter.next()) |symbol| {
            try stdout.writer().print("- {s} {s} => 0x{X:0>4} = 0x{X:0>4}\n", .{
                mutable_names[@boolToInt(symbol.value_ptr.isMutable())],
                symbol.key_ptr.*,
                symbol.value_ptr.address,
                std.mem.readIntLittle(u16, env.memory[symbol.value_ptr.address..][0..2]),
            });
        }
    }

    var interpreter = Interpreter.init(gpa.allocator(), &env, ast);
    try interpreter.run();
}

const SymbolKind = enum {
    @"var",
    @"fn",
    @"const",
};

const Symbol = struct {
    kind: SymbolKind,
    address: u16,

    pub fn isMutable(self: @This()) bool {
        return (self.kind == .@"var");
    }
};

const Environment = struct {
    const Self = @This();

    memory: [65536]u8,

    globals: std.StringHashMap(Symbol),

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .memory = undefined,
            .globals = std.StringHashMap(Symbol).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.globals.deinit();
        self.* = undefined;
    }
};

const Interpreter = struct {
    const Self = @This();

    env: *Environment,
    ast: Ast,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, env: *Environment, ast: Ast) Self {
        return Self{
            .env = env,
            .ast = ast,
            .allocator = allocator,
        };
    }

    pub fn run(self: Self) !void {
        _ = self;
    }

    const EvalError = error{ FunctionNotFound, OutOfMemory };
    pub fn evaluate(self: Self, expr: Ast.Expression) EvalError!u16 {
        return switch (expr) {
            .number => |num| std.fmt.parseInt(u16, num, 0) catch unreachable, // we checked that in sema
            .identifier => |ident| std.mem.readIntLittle(
                u16,
                self.env.memory[self.env.globals.get(ident).?.address..][0..2],
            ),

            .string => @panic("strings not implemented yet"),
            .binary_operation => |op| blk: {
                const lhs = try self.evaluate(op.lhs.*);
                const rhs = try self.evaluate(op.rhs.*);
                break :blk switch (op.operator) {
                    .@"+" => lhs +% rhs,
                    .@"-" => lhs -% rhs,
                    .@"*" => lhs *% rhs,
                    .@"/" => lhs / rhs,
                    .@"%" => lhs % rhs,
                    .@"&" => lhs & rhs,
                    .@"|" => lhs | rhs,
                    .@"^" => lhs ^ rhs,
                    .@">" => @boolToInt(lhs > rhs),
                    .@"<" => @boolToInt(lhs < rhs),
                    .@">=" => @boolToInt(lhs >= rhs),
                    .@"<=" => @boolToInt(lhs <= rhs),
                    .@"==" => @boolToInt(lhs == rhs),
                    .@"!=" => @boolToInt(lhs != rhs),
                    .@"and" => @boolToInt((lhs != 0) and (rhs != 0)),
                    .@"or" => @boolToInt((lhs != 0) or (rhs != 0)),
                };
            },
            .unary_operation => |op| switch (op.operator) {
                .@"-" => 0 -% (try self.evaluate(op.value.*)),
                .@"~" => ~(try self.evaluate(op.value.*)),
                .@"!" => @boolToInt((try self.evaluate(op.value.*)) != 0),
                .@"&" => @panic("address of not implemented yet!"),
                .@"<<" => (try self.evaluate(op.value.*)) << 1,
                .@">>" => (try self.evaluate(op.value.*)) >> 1,
                .@">>>" => blk: {
                    const val = try self.evaluate(op.value.*);
                    break :blk (0x8000 & val) | (val) >> 1;
                },
            },
            .indexing => |op| blk: {
                const address = try self.evaluate(op.value.*);
                const index = try self.evaluate(op.index.*);

                break :blk switch (op.word_size) {
                    .byte => std.mem.readIntLittle(u8, self.env.memory[address + index ..][0..1]),
                    .word => std.mem.readIntLittle(u16, self.env.memory[address + index ..][0..2]),
                };
            },
            .call => |call| blk: {
                const func_addr = try self.evaluate(call.function.*);

                var argv = std.ArrayList(u16).init(self.allocator);
                defer argv.deinit();

                {
                    var maybe_arg = call.args;
                    while (maybe_arg) |arg| : (maybe_arg = arg.next) {
                        const value = try self.evaluate(arg.value.*);
                        try argv.append(value);
                    }
                }

                const function = self.addr2name(func_addr) orelse return error.FunctionNotFound;

                const result = try self.call(function, argv.items);

                std.debug.print(
                    "call: {} ({s})(* {d}) => {} \n",
                    .{ func_addr, function, argv.items.len, result },
                );

                break :blk result;
            },
            .array_init => @panic("array initializer not implemented yet"),
        };
    }

    pub fn call(self: Self, function: []const u8, argv: []const u16) EvalError!u16 {
        var top_level = self.ast.top_level;
        const func: Ast.FnDeclaration = while (top_level) |decl| : (top_level = decl.next) {
            if (decl.data == .@"fn") {
                if (std.mem.eql(u8, decl.data.@"fn".name, function))
                    break decl.data.@"fn";
            }
        } else return error.FunctionNotFound;

        std.debug.print("func: {}\n", .{func});

        _ = self;
        _ = function;
        _ = argv;
        //
        return 0xABCD;
    }

    pub fn addr2name(self: Self, addr: u16) ?[]const u8 {
        var iter = self.env.globals.iterator();
        while (iter.next()) |sym| {
            if (sym.value_ptr.address == addr)
                return sym.key_ptr.*;
        }
        return null;
    }
};

pub const SemanticAnalysis = struct {
    const Self = @This();

    const AnalysisError = error{OutOfMemory};

    allocator: std.mem.Allocator,
    diagnostics: *ptk.Diagnostics,
    ast: Ast,
    env: *Environment,

    write_pointer: u16,

    pub fn check(allocator: std.mem.Allocator, diagnostics: *ptk.Diagnostics, ast: Ast) !Environment {
        var memory = std.heap.ArenaAllocator.init(allocator);
        defer memory.deinit();

        var env = Environment.init(allocator);
        errdefer env.deinit();

        var sema = SemanticAnalysis{
            .diagnostics = diagnostics,
            .ast = ast,
            .env = &env,
            .allocator = allocator,
            .write_pointer = 0,
        };

        var next_decl = ast.top_level;
        while (next_decl) |decl| : (next_decl = decl.next) {
            const name = switch (decl.data) {
                .@"var" => |val| val.name,
                .@"const" => |val| val.name,
                .@"fn" => |val| val.name,
            };

            const gop = try env.globals.getOrPut(name);
            if (gop.found_existing) {
                try diagnostics.emit(ptk.Location.empty, .@"error", "A symbol with the name `{s}` already exists.", .{name});
            }

            try sema.alignPointer(2);

            var symbol = gop.value_ptr;
            symbol.* = Symbol{
                .kind = std.meta.activeTag(decl.data),
                .address = sema.write_pointer,
            };

            // std.debug.print("analyze {s} => {}\n", .{ gop.key_ptr.*, symbol.* });

            switch (decl.data) {
                .@"var" => |d| if (d.value) |value| {
                    if (try sema.validateExpr(value, &.{})) {
                        var interpreter = Interpreter.init(allocator, &env, ast);

                        const init_value = try interpreter.evaluate(value.*);
                        try sema.write16(init_value);
                    } else {
                        try sema.write16(0xAAAA);
                    }
                } else {
                    try sema.write16(0); // default to zero
                },
                .@"const" => |d| if (try sema.validateExpr(d.value, &.{})) {
                    var interpreter = Interpreter.init(allocator, &env, ast);

                    const init_value = try interpreter.evaluate(d.value.*);
                    try sema.write16(init_value);
                } else {
                    try sema.write16(0xAAAA);
                },
                .@"fn" => |d| {
                    _ = try sema.validateFunction(d);

                    // for interpreter, emit address to self
                    try sema.write16(symbol.address);
                },
            }
        }

        return env;
    }

    fn alignPointer(self: *Self, alignment: u16) !void {
        self.write_pointer = try std.math.cast(u16, std.mem.alignForward(self.write_pointer, alignment));
    }

    fn tryMovePointer(self: Self, size: u16) !u16 {
        if (self.write_pointer >= std.math.maxInt(u16) - size)
            return error.Overflow;
        return self.write_pointer + size;
    }

    fn write8(self: *Self, value: u8) !void {
        const next = try self.tryMovePointer(1);
        std.mem.writeIntLittle(u8, self.env.memory[self.write_pointer..][0..1], value);
        self.write_pointer = next;
    }

    fn write16(self: *Self, value: u16) !void {
        const next = try self.tryMovePointer(2);
        std.mem.writeIntLittle(u16, self.env.memory[self.write_pointer..][0..2], value);
        self.write_pointer = next;
    }

    fn validateFunction(self: Self, func: Ast.FnDeclaration) AnalysisError!bool {
        var locals = std.ArrayList([]const u8).init(self.allocator);
        defer locals.deinit();

        var arg = func.parameters;
        while (arg) |a| : (arg = a.next) {
            try locals.append(a.name);
        }

        return try self.validateBlock(func.body, &locals);
    }

    fn validateBlock(self: Self, statement: *Ast.Statement, locals: *std.ArrayList([]const u8)) AnalysisError!bool {
        var good = Fuse{};

        // Allow variables with local scope to be declared until end-of-block.
        // This allows simple reuse of stack slots.
        const length = locals.items.len;
        defer locals.shrinkRetainingCapacity(length);

        var iter: ?*Ast.Statement = statement;
        while (iter) |stmt| : (iter = stmt.next) {
            good.update(try self.validateStatement(stmt, locals));
        }

        return good.state;
    }

    fn validateStatement(self: Self, statement: *Ast.Statement, locals: *std.ArrayList([]const u8)) AnalysisError!bool {
        var good = Fuse{};
        switch (statement.data) {
            .empty, .@"break", .@"continue" => {},

            .expression => |expr| good.update(try self.validateExpr(expr, locals.items)),
            .assignment => |ass| {
                if (!ass.target.isLValue()) {
                    try self.diagnostics.emit(
                        ptk.Location.empty,
                        .@"error",
                        "Left hand side of an assignment must be an lvalue.",
                        .{},
                    );
                    good.burn();
                }

                good.update(try self.validateExpr(ass.target, locals.items));
                good.update(try self.validateExpr(ass.value, locals.items));

                return good.state;
            },
            .conditional => |cond| {
                good.update(try self.validateExpr(cond.condition, locals.items));

                good.update(try self.validateBlock(cond.true_branch, locals));
                if (cond.false_branch) |false_branch| {
                    good.update(try self.validateBlock(false_branch, locals));
                }
            },
            .loop => |loop| {
                good.update(try self.validateExpr(loop.condition, locals.items));
                good.update(try self.validateBlock(loop.body, locals));
            },
            .local => |local| {
                if (local.value) |value| {
                    good.update(try self.validateExpr(value, locals.items));
                }
                try locals.append(local.name);
            },

            .@"return" => |maybe_expr| if (maybe_expr) |expr| {
                good.update(try self.validateExpr(expr, locals.items));
            },
        }
        return good.state;
    }

    fn validateExpr(self: Self, expression: *Ast.Expression, locals: []const []const u8) AnalysisError!bool {
        var good = Fuse{};
        switch (expression.*) {
            .number => |val| {
                _ = std.fmt.parseInt(u16, val, 0) catch {
                    try self.diagnostics.emit(ptk.Location.empty, .@"error", "The number `{s}` is out of range. Valid numbers are between 0 and 65535.", .{val});
                    good.burn();
                };
            },
            .identifier => |ident| {
                var exists = (getLocal(locals, ident) != null);
                if (!exists) {
                    exists = (self.env.globals.get(ident) != null);
                }
                good.update(exists);
                if (good.state == false) {
                    try self.diagnostics.emit(ptk.Location.empty, .@"error", "The function or variable `{s}` does not exist.", .{ident});
                }
            },
            .string => {
                @panic("string analysis not implemented yet!");
            },
            .binary_operation => |op| {
                good.update(try self.validateExpr(op.lhs, locals));
                good.update(try self.validateExpr(op.rhs, locals));
            },
            .unary_operation => |op| good.update(try self.validateExpr(op.value, locals)),
            .indexing => |op| {
                good.update(try self.validateExpr(op.value, locals));
                good.update(try self.validateExpr(op.index, locals));
            },
            .call => |call| {
                good.update(try self.validateExpr(call.function, locals));

                var argc: usize = 0;
                var iter = ListIterator.init(call.args);
                while (iter.next()) |arg| {
                    good.update(try self.validateExpr(arg.value, locals));
                    argc += 1;
                }

                if (call.function.* == .identifier) {
                    if (self.env.globals.get(call.function.identifier)) |glob| {
                        if (glob.kind != .@"fn") {
                            try self.diagnostics.emit(ptk.Location.empty, .warning, "The callee `{s}` is not a function. This might be a mistake.", .{call.function.identifier});
                        }
                    }

                    // computeListLen(

                } else {
                    // we cannot be sure about stuff
                }
            },
            .array_init => |init| {
                var iter = ListIterator.init(init.values);
                while (iter.next()) |arg| {
                    good.update(try self.validateExpr(arg.value, locals));
                }
            },
        }
        return good.state;
    }

    const ListIterator = struct {
        list: ?*Ast.ValueList,

        fn init(list: ?*Ast.ValueList) @This() {
            return @This(){
                .list = list,
            };
        }

        pub fn next(self: *@This()) ?*Ast.ValueList {
            if (self.list) |current| {
                self.list = current.next;
                return current;
            } else {
                return null;
            }
        }
    };

    fn getLocal(locals: []const []const u8, name: []const u8) ?usize {
        var i = locals.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, locals[i], name))
                return i;
        }
        return null;
    }

    const Fuse = struct {
        state: bool = true,

        pub fn update(self: *@This(), good: bool) void {
            if (!good)
                self.state = false;
        }

        pub fn burn(self: *@This()) void {
            self.state = false;
        }
    };
};

pub const Parser = struct {
    const Self = @This();
    const Rules = ptk.RuleSet(TokenType);
    const Error = error{ OutOfMemory, SyntaxError } || ParserCore.AcceptError;

    pub fn parse(allocator: std.mem.Allocator, source: []const u8, file_name: ?[]const u8) Error!Ast {
        var tokenizer = Tokenizer.init(source, file_name);
        var core = ParserCore.init(&tokenizer);

        var ast = Ast.init(allocator);
        errdefer ast.deinit();

        errdefer std.log.err("syntax error at {}", .{
            tokenizer.current_location,
        });

        var previous: ?*Ast.TopLevelDeclaration = null;
        while (try core.nextToken()) |token| {
            const node = try ast.alloc(Ast.TopLevelDeclaration);
            node.* = .{
                .next = null,
                .data = undefined,
            };
            node.data =
                switch (token.type) {
                .@"var" => try parseVarDecl(&ast, &core),
                .@"const" => try parseConstDecl(&ast, &core),
                .@"fn" => try parseFnDecl(&ast, &core),
                else => return error.SyntaxError,
            };

            if (previous) |prev| {
                prev.next = node;
            } else {
                ast.top_level = node;
            }
            previous = node;
        }

        return ast;
    }

    fn parseVarDecl(ast: *Ast, parser: *ParserCore) Error!Ast.TopLevelDeclaration.Data {
        const ident = try parser.accept(comptime Rules.is(.identifier));

        const eql_or_semicolon = try parser.accept(comptime Rules.oneOf(.{ .@";", .@"=" }));
        if (eql_or_semicolon.type == .@";") {
            return Ast.TopLevelDeclaration.Data{
                .@"var" = Ast.VarDeclaration{
                    .name = ident.text,
                    .value = null,
                },
            };
        }

        const expr = try parseExpression(ast, parser);

        _ = try parser.accept(comptime Rules.is(.@";"));

        return Ast.TopLevelDeclaration.Data{
            .@"var" = Ast.VarDeclaration{
                .name = ident.text,
                .value = expr,
            },
        };
    }
    fn parseConstDecl(ast: *Ast, parser: *ParserCore) Error!Ast.TopLevelDeclaration.Data {
        const ident = try parser.accept(comptime Rules.is(.identifier));

        _ = try parser.accept(comptime Rules.is(.@"="));

        const expr = try parseExpression(ast, parser);

        _ = try parser.accept(comptime Rules.is(.@";"));

        return Ast.TopLevelDeclaration.Data{
            .@"const" = Ast.ConstDeclaration{
                .name = ident.text,
                .value = expr,
            },
        };
    }
    fn parseFnDecl(ast: *Ast, parser: *ParserCore) Error!Ast.TopLevelDeclaration.Data {
        const ident = try parser.accept(comptime Rules.is(.identifier));
        _ = try parser.accept(comptime Rules.is(.@"("));

        var fndecl = Ast.FnDeclaration{
            .name = ident.text,
            .parameters = null,
            .body = undefined,
        };

        var first_param_or_eoa = try parser.accept(comptime Rules.oneOf(.{ .identifier, .@")" }));
        if (first_param_or_eoa.type == .identifier) {
            var previous = try ast.alloc(Ast.Parameter);
            previous.* = .{
                .name = first_param_or_eoa.text,
                .next = null,
            };
            fndecl.parameters = previous;

            while (true) {
                var next_or_eol = try parser.accept(comptime Rules.oneOf(.{ .@")", .@"," }));
                if (next_or_eol.type == .@")")
                    break;

                const name = try parser.accept(comptime Rules.is(.identifier));

                const arg = try ast.alloc(Ast.Parameter);
                arg.* = .{
                    .name = name.text,
                    .next = null,
                };

                previous.next = arg;
                previous = arg;
            }
        }

        fndecl.body = try parseBlock(ast, parser);

        return Ast.TopLevelDeclaration.Data{
            .@"fn" = fndecl,
        };
    }

    fn parseBlock(ast: *Ast, parser: *ParserCore) Error!*Ast.Statement {
        _ = try parser.accept(comptime Rules.is(.@"{"));

        var first: ?*Ast.Statement = null;
        var previous: ?*Ast.Statement = null;

        while (true) {
            if (parser.accept(comptime Rules.is(.@"}"))) |_| {
                return first orelse {
                    const item = try ast.alloc(Ast.Statement);
                    item.* = Ast.Statement{
                        .data = .empty,
                        .next = null,
                    };
                    return item;
                };
            } else |_| {
                const statement = try parseStatement(ast, parser);

                if (first == null) {
                    first = statement;
                }
                if (previous) |prev| {
                    prev.next = statement;
                }
                previous = statement;
            }
        }
    }

    fn parseStatement(ast: *Ast, parser: *ParserCore) Error!*Ast.Statement {
        if (try parser.peek()) |preview| {
            switch (preview.type) {
                .@"continue" => {
                    _ = try parser.accept(comptime Rules.is(.@"continue"));
                    _ = try parser.accept(comptime Rules.is(.@";"));

                    const item = try ast.alloc(Ast.Statement);
                    item.* = Ast.Statement{
                        .data = .@"continue",
                        .next = null,
                    };
                    return item;
                },
                .@"break" => {
                    _ = try parser.accept(comptime Rules.is(.@"break"));
                    _ = try parser.accept(comptime Rules.is(.@";"));

                    const item = try ast.alloc(Ast.Statement);
                    item.* = Ast.Statement{
                        .data = .@"break",
                        .next = null,
                    };
                    return item;
                },
                .@"return" => {
                    _ = try parser.accept(comptime Rules.is(.@"return"));

                    if (parser.accept(comptime Rules.is(.@";"))) |_| {
                        const item = try ast.alloc(Ast.Statement);
                        item.* = Ast.Statement{
                            .data = .{ .@"return" = null },
                            .next = null,
                        };
                        return item;
                    } else |_| {
                        const value = try parseExpression(ast, parser);

                        _ = try parser.accept(comptime Rules.is(.@";"));

                        const item = try ast.alloc(Ast.Statement);
                        item.* = Ast.Statement{
                            .data = .{ .@"return" = value },
                            .next = null,
                        };
                        return item;
                    }
                },
                .@"if" => {
                    _ = try parser.accept(comptime Rules.is(.@"if"));
                    _ = try parser.accept(comptime Rules.is(.@"("));

                    const condition = try parseExpression(ast, parser);

                    _ = try parser.accept(comptime Rules.is(.@")"));

                    const true_block = try parseBlock(ast, parser);

                    const false_branch = if (parser.accept(comptime Rules.is(.@"else"))) |_|
                        try parseBlock(ast, parser)
                    else |_|
                        null;

                    const item = try ast.alloc(Ast.Statement);
                    item.* = Ast.Statement{
                        .data = .{
                            .conditional = Ast.Conditional{
                                .condition = condition,
                                .true_branch = true_block,
                                .false_branch = false_branch,
                            },
                        },
                        .next = null,
                    };
                    return item;
                },
                .@"while" => {
                    _ = try parser.accept(comptime Rules.is(.@"while"));
                    _ = try parser.accept(comptime Rules.is(.@"("));

                    const condition = try parseExpression(ast, parser);

                    _ = try parser.accept(comptime Rules.is(.@")"));

                    const block = try parseBlock(ast, parser);
                    const item = try ast.alloc(Ast.Statement);
                    item.* = Ast.Statement{
                        .data = .{
                            .loop = Ast.Loop{
                                .condition = condition,
                                .body = block,
                            },
                        },
                        .next = null,
                    };
                    return item;
                },

                .@"var" => {
                    _ = try parser.accept(comptime Rules.is(.@"var"));
                    const data = try parseVarDecl(ast, parser);

                    const item = try ast.alloc(Ast.Statement);
                    item.* = Ast.Statement{
                        .data = .{ .local = data.@"var" },
                        .next = null,
                    };
                    return item;
                },

                .@";" => {
                    _ = try parser.accept(comptime Rules.is(.@";"));
                    const item = try ast.alloc(Ast.Statement);
                    item.* = Ast.Statement{
                        .data = .empty,
                        .next = null,
                    };
                    return item;
                },

                .@"{" => return try parseBlock(ast, parser),

                else => {},
            }
        }

        const expression = try parseExpression(ast, parser);
        if (parser.accept(comptime Rules.is(.@"="))) |_| {
            const value = try parseExpression(ast, parser);
            _ = try parser.accept(comptime Rules.is(.@";"));

            const item = try ast.alloc(Ast.Statement);
            item.* = Ast.Statement{
                .data = .{ .assignment = Ast.Assignment{
                    .target = expression,
                    .value = value,
                } },
                .next = null,
            };
            return item;
        } else |_| {
            _ = try parser.accept(comptime Rules.is(.@";"));

            const item = try ast.alloc(Ast.Statement);
            item.* = Ast.Statement{
                .data = .{ .expression = expression },
                .next = null,
            };
            return item;
        }
    }

    fn parseExpression(ast: *Ast, parser: *ParserCore) Error!*Ast.Expression {
        return try parseBinaryOpExpression(ast, parser);
    }

    fn parseBinaryOpExpression(ast: *Ast, parser: *ParserCore) Error!*Ast.Expression {
        const lhs = try parsePrefixOpExpression(ast, parser);

        const any_binop = comptime enumToTokenSet(BinaryOperator);

        if (parser.accept(comptime Rules.oneOf(any_binop))) |op| {
            const operator = tokenToEnumVal(op.type, BinaryOperator);

            const rhs = try parseBinaryOpExpression(ast, parser);

            return try ast.memoize(Ast.Expression{
                .binary_operation = .{
                    .lhs = lhs,
                    .rhs = rhs,
                    .operator = operator,
                },
            });
        } else |_| {
            return lhs;
        }
    }
    fn parsePrefixOpExpression(ast: *Ast, parser: *ParserCore) Error!*Ast.Expression {
        const any_unop = comptime enumToTokenSet(UnaryOperator);

        if (parser.accept(comptime Rules.oneOf(any_unop))) |op| {
            const operator = tokenToEnumVal(op.type, UnaryOperator);
            const value = try parsePrefixOpExpression(ast, parser);

            return try ast.memoize(Ast.Expression{
                .unary_operation = .{
                    .value = value,
                    .operator = operator,
                },
            });
        } else |_| {
            return try parseSuffixOpExpression(ast, parser);
        }
    }

    fn parseSuffixOpExpression(ast: *Ast, parser: *ParserCore) Error!*Ast.Expression {
        var expr = try parseAtomExpression(ast, parser);

        while (parser.accept(comptime Rules.oneOf(.{ .@"@", .@"[", .@"(" }))) |op| {
            switch (op.type) {
                .@"@" => {
                    if (parser.accept(comptime Rules.is(.number))) |number| {
                        const index = try ast.memoize(Ast.Expression{ .number = number.text });

                        const value = expr;
                        expr = try ast.memoize(Ast.Expression{
                            .indexing = .{
                                .word_size = .byte,
                                .value = value,
                                .index = index,
                            },
                        });
                    } else |_| {
                        _ = try parser.accept(comptime Rules.is(.@"("));
                        const index = try parseExpression(ast, parser);
                        _ = try parser.accept(comptime Rules.is(.@")"));

                        const value = expr;
                        expr = try ast.memoize(Ast.Expression{
                            .indexing = .{
                                .word_size = .byte,
                                .value = value,
                                .index = index,
                            },
                        });
                    }
                },
                .@"[" => {
                    const index = try parseExpression(ast, parser);
                    _ = try parser.accept(comptime Rules.is(.@"]"));

                    const value = expr;
                    expr = try ast.memoize(Ast.Expression{
                        .indexing = .{
                            .word_size = .word,
                            .value = value,
                            .index = index,
                        },
                    });
                },
                .@"(" => {
                    var call = Ast.Call{
                        .function = expr,
                        .args = null,
                    };

                    call.args = try parseValueList(ast, parser, .@")");
                    expr = try ast.memoize(Ast.Expression{
                        .call = call,
                    });
                },

                else => unreachable,
            }
        } else |_| {
            return expr;
        }
    }

    fn parseAtomExpression(ast: *Ast, parser: *ParserCore) Error!*Ast.Expression {
        const start_token = try parser.accept(comptime Rules.oneOf(.{ .number, .identifier, .@"(", .@"[", .@"{" }));
        return switch (start_token.type) {
            .number => try ast.memoize(Ast.Expression{ .number = start_token.text }),
            .identifier => try ast.memoize(Ast.Expression{ .identifier = start_token.text }),

            .@"{" => {
                const list = try parseValueList(ast, parser, .@"}");
                return try ast.memoize(Ast.Expression{ .array_init = .{
                    .word_size = .byte,
                    .values = list,
                } });
            },

            .@"[" => {
                const list = try parseValueList(ast, parser, .@"]");
                return try ast.memoize(Ast.Expression{ .array_init = .{
                    .word_size = .word,
                    .values = list,
                } });
            },

            .@"(" => {
                const expr = try parseExpression(ast, parser);
                _ = try parser.accept(comptime Rules.is(.@")"));
                return expr;
            },

            else => return error.SyntaxError,
        };
    }

    fn parseValueList(ast: *Ast, parser: *ParserCore, comptime delimiter: TokenType) Error!?*Ast.ValueList {
        var head: ?*Ast.ValueList = null;
        if (parser.accept(comptime Rules.is(delimiter))) |_| {
            // everything fine here
        } else |_| {
            var previous_item: ?*Ast.ValueList = null;
            while (true) {
                const value = try parseExpression(ast, parser);

                const item = try ast.memoize(Ast.ValueList{
                    .value = value,
                    .next = null,
                });

                if (previous_item) |prev| {
                    prev.next = item;
                }
                if (head == null) {
                    head = item;
                }
                previous_item = item;

                const delimit = try parser.accept(comptime Rules.oneOf(.{ .@",", delimiter }));
                if (delimit.type == delimiter)
                    break;
            }
        }
        return head;
    }
};

fn AstPrinter(comptime Writer: type) type {
    return struct {
        pub const Error = Writer.Error;

        const indent_char = " ";
        const indent_level = 4;

        fn print(ast: Ast, writer: Writer) Error!void {
            var next_node = ast.top_level;
            while (next_node) |node| : (next_node = node.next) {
                switch (node.data) {
                    .@"var" => |val| try printVarDecl(val, writer),
                    .@"const" => |val| try printConstDecl(val, writer),
                    .@"fn" => |val| try printFnDecl(val, writer),
                }
                if (node.next != null) {
                    try writer.writeAll("\n");
                }
            }
        }

        fn printVarDecl(decl: Ast.VarDeclaration, writer: Writer) Error!void {
            if (decl.value) |value| {
                try writer.print("var {s} = ", .{decl.name});
                try printExpr(value.*, writer);
                try writer.writeAll(";\n");
            } else {
                try writer.print("var {s};\n", .{decl.name});
            }
        }

        fn printConstDecl(decl: Ast.ConstDeclaration, writer: Writer) Error!void {
            try writer.print("const {s} = ", .{decl.name});
            try printExpr(decl.value.*, writer);
            try writer.writeAll(";\n");
        }

        fn printFnDecl(decl: Ast.FnDeclaration, writer: Writer) Error!void {
            try writer.print("fn {s}(", .{decl.name});

            var first_param = decl.parameters;
            while (first_param) |param| : (first_param = param.next) {
                try writer.print("{s}", .{param.name});
                if (param.next != null) {
                    try writer.writeAll(", ");
                }
            }

            try writer.writeAll(") ");

            try printBlock(decl.body, 0, writer);
        }

        fn printBlock(stmt: *Ast.Statement, indent: usize, writer: Writer) Error!void {
            try writer.writeAll("{\n");

            var iter: ?*Ast.Statement = stmt;
            while (iter) |item| : (iter = item.next) {
                try printStatement(item.*, indent + indent_level, writer);
            }

            try printIndent(indent, writer);
            try writer.writeAll("}\n");
        }

        fn printStatement(stmt: Ast.Statement, indent: usize, writer: Writer) Error!void {
            try printIndent(indent, writer);
            switch (stmt.data) {
                .empty => try writer.writeAll(";\n"),
                .expression => |val| {
                    try printExpr(val.*, writer);
                    try writer.writeAll(";\n");
                },
                .assignment => |val| {
                    try printExpr(val.target.*, writer);
                    try writer.writeAll(" = ");
                    try printExpr(val.value.*, writer);
                    try writer.writeAll(";\n");
                },
                .conditional => |val| {
                    try writer.writeAll("if (");
                    try printExpr(val.condition.*, writer);
                    try writer.writeAll(") ");
                    try printBlock(val.true_branch, indent, writer);
                    if (val.false_branch) |false_branch| {
                        try printIndent(indent, writer);
                        try writer.writeAll("else ");
                        try printBlock(false_branch, indent, writer);
                    }
                },
                .loop => |val| {
                    try writer.writeAll("while (");
                    try printExpr(val.condition.*, writer);
                    try writer.writeAll(") ");
                    try printBlock(val.body, indent, writer);
                },
                .@"break" => try writer.writeAll("break;\n"),
                .@"continue" => try writer.writeAll("continue;\n"),
                .@"return" => |val| {
                    if (val) |expr| {
                        try writer.writeAll("return ");
                        try printExpr(expr.*, writer);
                        try writer.writeAll(";\n");
                    } else {
                        try writer.writeAll("return;\n");
                    }
                },
                .local => |decl| {
                    try printIndent(indent, writer);
                    try printVarDecl(decl, writer);
                },
            }
        }

        fn printExpr(expr: Ast.Expression, writer: Writer) Error!void {
            // try writer.writeAll("( ");
            // defer writer.writeAll(" )") catch {};

            switch (expr) {
                .number => |val| try writer.writeAll(val),
                .identifier => |val| try writer.writeAll(val),
                .string => |val| try writer.writeAll(val),
                .binary_operation => |val| {
                    try writer.writeAll("(");
                    try printExpr(val.lhs.*, writer);
                    try writer.print(" {s} ", .{@tagName(val.operator)});
                    try printExpr(val.rhs.*, writer);
                    try writer.writeAll(")");
                },
                .unary_operation => |val| {
                    try writer.writeAll("(");
                    try writer.writeAll(@tagName(val.operator));
                    try printExpr(val.value.*, writer);
                    try writer.writeAll(")");
                },
                .indexing => |val| switch (val.word_size) {
                    .byte => {
                        try printExpr(val.value.*, writer);

                        if (val.index.* == .number) {
                            try writer.writeAll("@");
                            try printExpr(val.index.*, writer);
                        } else {
                            try writer.writeAll("(");
                            try printExpr(val.index.*, writer);
                            try writer.writeAll(")");
                        }
                    },
                    .word => {
                        try printExpr(val.value.*, writer);
                        try writer.writeAll("[");
                        try printExpr(val.index.*, writer);
                        try writer.writeAll("]");
                    },
                },
                .call => |val| {
                    try printExpr(val.function.*, writer);
                    try writer.writeAll("(");
                    var current_arg = val.args;
                    while (current_arg) |arg| : (current_arg = arg.next) {
                        try printExpr(arg.value.*, writer);
                        if (arg.next != null) {
                            try writer.writeAll(", ");
                        }
                    }
                    try writer.writeAll(")");
                },
                .array_init => |val| {
                    const braces = switch (val.word_size) {
                        .byte => "{}",
                        .word => "[]",
                    };
                    try writer.writeAll(braces[0..1]);
                    var current_arg = val.values;
                    while (current_arg) |arg| : (current_arg = arg.next) {
                        try printExpr(arg.value.*, writer);
                        if (arg.next != null) {
                            try writer.writeAll(", ");
                        }
                    }
                    try writer.writeAll(braces[1..2]);
                },
            }
        }

        fn printIndent(indent: usize, writer: Writer) Error!void {
            const padding = indent_char.* ** 64;
            var i: usize = 0;
            while (i < indent) {
                const l = std.math.min(padding.len, indent - i);
                try writer.writeAll(padding[0..l]);
                i += l;
            }
        }
    };
}

const TokenType = enum(u8) {
    whitespace,
    comment,

    identifier,
    number,

    @"var",
    @"const",
    @"fn",
    @"and",
    @"or",
    @"continue",
    @"break",
    @"return",
    @"if",
    @"else",
    @"while",

    @",",
    @"=",
    @";",
    @"{",
    @"}",
    @"[",
    @"]",
    @"(",
    @")",
    @"+",
    @"-",
    @"*",
    @"/",
    @"%",
    @"&",
    @"|",
    @"^",
    @">",
    @"<",
    @">=",
    @"<=",
    @"==",
    @"!=",
    @">>",
    @">>>",
    @"<<",
    @"!",
    @"~",
    @"@",
};

const Pattern = ptk.Pattern(TokenType);
const Tokenizer = ptk.Tokenizer(TokenType, &.{
    Pattern.create(.whitespace, ptk.matchers.whitespace),
    Pattern.create(.comment, ptk.matchers.sequenceOf(.{ ptk.matchers.literal("#"), ptk.matchers.takeNoneOf("\n"), ptk.matchers.literal("\n") })),
    Pattern.create(.comment, ptk.matchers.sequenceOf(.{ ptk.matchers.literal("#"), ptk.matchers.literal("\n") })),

    Pattern.create(.@"var", ptk.matchers.word("var")),
    Pattern.create(.@"const", ptk.matchers.word("const")),
    Pattern.create(.@"fn", ptk.matchers.word("fn")),
    Pattern.create(.@"and", ptk.matchers.word("and")),
    Pattern.create(.@"or", ptk.matchers.word("or")),
    Pattern.create(.@"continue", ptk.matchers.word("continue")),
    Pattern.create(.@"break", ptk.matchers.word("break")),
    Pattern.create(.@"return", ptk.matchers.word("return")),
    Pattern.create(.@"if", ptk.matchers.word("if")),
    Pattern.create(.@"else", ptk.matchers.word("else")),
    Pattern.create(.@"while", ptk.matchers.word("while")),

    Pattern.create(.@">>>", ptk.matchers.literal(">>>")),

    Pattern.create(.@">=", ptk.matchers.literal(">=")),
    Pattern.create(.@"<=", ptk.matchers.literal("<=")),
    Pattern.create(.@"==", ptk.matchers.literal("==")),
    Pattern.create(.@"!=", ptk.matchers.literal("!=")),
    Pattern.create(.@">>", ptk.matchers.literal(">>")),
    Pattern.create(.@"<<", ptk.matchers.literal("<<")),

    Pattern.create(.@";", ptk.matchers.literal(";")),
    Pattern.create(.@"{", ptk.matchers.literal("{")),
    Pattern.create(.@"}", ptk.matchers.literal("}")),
    Pattern.create(.@"[", ptk.matchers.literal("[")),
    Pattern.create(.@"]", ptk.matchers.literal("]")),
    Pattern.create(.@"(", ptk.matchers.literal("(")),
    Pattern.create(.@")", ptk.matchers.literal(")")),
    Pattern.create(.@"+", ptk.matchers.literal("+")),
    Pattern.create(.@"-", ptk.matchers.literal("-")),
    Pattern.create(.@"*", ptk.matchers.literal("*")),
    Pattern.create(.@"/", ptk.matchers.literal("/")),
    Pattern.create(.@"%", ptk.matchers.literal("%")),
    Pattern.create(.@"&", ptk.matchers.literal("&")),
    Pattern.create(.@"|", ptk.matchers.literal("|")),
    Pattern.create(.@"^", ptk.matchers.literal("^")),
    Pattern.create(.@">", ptk.matchers.literal(">")),
    Pattern.create(.@"<", ptk.matchers.literal("<")),
    Pattern.create(.@"!", ptk.matchers.literal("!")),
    Pattern.create(.@"~", ptk.matchers.literal("~")),
    Pattern.create(.@"=", ptk.matchers.literal("=")),
    Pattern.create(.@",", ptk.matchers.literal(",")),
    Pattern.create(.@"@", ptk.matchers.literal("@")),

    Pattern.create(.identifier, ptk.matchers.identifier),
    Pattern.create(.number, ptk.matchers.decimalNumber),
});

const ParserCore = ptk.ParserCore(Tokenizer, .{ .comment, .whitespace });

const Ast = struct {
    const Self = @This();

    memory: std.heap.ArenaAllocator,
    top_level: ?*TopLevelDeclaration,

    pub fn init(allocator: std.mem.Allocator) Ast {
        return Ast{
            .memory = std.heap.ArenaAllocator.init(allocator),
            .top_level = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.memory.deinit();
        self.* = undefined;
    }

    /// Allocates a new `T` in the memory of the Ast.
    fn alloc(self: *Self, comptime T: type) !*T {
        return try self.memory.allocator().create(T);
    }

    /// Puts `value` into the Ast memory and returns a pointer to it.
    fn memoize(self: *Self, value: anytype) !*@TypeOf(value) {
        const ptr = try self.alloc(@TypeOf(value));
        ptr.* = value;
        return ptr;
    }

    pub const TopLevelDeclaration = struct {
        next: ?*@This(),
        data: Data,

        const Data = union(SymbolKind) {
            @"var": VarDeclaration,
            @"const": ConstDeclaration,
            @"fn": FnDeclaration,
        };
    };

    pub const VarDeclaration = struct {
        name: []const u8,
        value: ?*Expression,
    };

    pub const ConstDeclaration = struct {
        name: []const u8,
        value: *Expression,
    };

    pub const FnDeclaration = struct {
        name: []const u8,
        parameters: ?*Parameter,
        body: *Statement,
    };

    pub const Parameter = struct {
        name: []const u8,
        next: ?*Parameter,
    };

    pub const Statement = struct {
        data: Data,
        next: ?*Statement,

        const Data = union(enum) {
            empty,
            expression: *Expression,
            assignment: Assignment,
            conditional: Conditional,
            loop: Loop,
            @"break",
            @"continue",
            @"return": ?*Expression,
            local: VarDeclaration,
        };
    };

    pub const Assignment = struct {
        target: *Expression,
        value: *Expression,
    };

    pub const Conditional = struct {
        condition: *Expression,
        true_branch: *Statement,
        false_branch: ?*Statement,
    };

    pub const Loop = struct {
        condition: *Expression,
        body: *Statement,
    };

    pub const Expression = union(enum) {
        number: []const u8,
        identifier: []const u8,
        string: []const u8,

        binary_operation: BinaryOperation,
        unary_operation: UnaryOperation,

        indexing: Indexer,

        call: Call,
        array_init: ArrayInitializer,

        pub fn isLValue(self: @This()) bool {
            return switch (self) {
                .indexing, .identifier => true,
                else => false,
            };
        }
    };

    pub const BinaryOperation = struct {
        lhs: *Expression,
        rhs: *Expression,
        operator: BinaryOperator,
    };

    pub const UnaryOperation = struct {
        value: *Expression,
        operator: UnaryOperator,
    };

    pub const Indexer = struct {
        value: *Expression,
        index: *Expression,

        word_size: MemoryAccessSize,
    };

    pub const Call = struct {
        function: *Expression,
        args: ?*ValueList,
    };

    pub const ArrayInitializer = struct {
        word_size: MemoryAccessSize,
        values: ?*ValueList,
    };

    pub const ValueList = struct {
        value: *Expression,
        next: ?*ValueList,
    };
};
pub const MemoryAccessSize = enum { byte, word };

pub const BinaryOperator = enum {
    @"+",
    @"-",
    @"*",
    @"/",
    @"%",
    @"&",
    @"|",
    @"^",
    @">",
    @"<",
    @">=",
    @"<=",
    @"==",
    @"!=",
    @"and",
    @"or",
};

pub const UnaryOperator = enum {
    @"-",
    @"~",
    @"!",
    @"&",
    @"<<",
    @">>",
    @">>>",
};

fn enumToTokenSet(comptime T: type) [std.meta.fields(T).len]TokenType {
    var toks: [std.meta.fields(T).len]TokenType = undefined;
    inline for (std.meta.fields(T)) |fld, i| {
        toks[i] = @field(TokenType, fld.name);
    }
    return toks;
}

fn tokenToEnumVal(token: TokenType, comptime T: type) T {
    inline for (std.meta.fields(T)) |fld| {
        if (token == @field(TokenType, fld.name))
            return @field(T, fld.name);
    }
    @panic("received invalid token. check the pattern matching before!");
}

fn computeListLen(ptr: anytype) usize {
    var count: usize = 0;
    var iter = ptr;
    while (iter) |p| : (iter = p.next) {
        count += 1;
    }
    return count;
}
