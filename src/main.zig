const std = @import("std");
const analysis = @import("analysis.zig");
const DocumentStore = @import("document_store.zig");
const URI = @import("uri.zig");
const ast = std.zig.ast;
const builtins = @import("builtins.zig");

usingnamespace @import("ast.zig");

pub fn getFieldAccessType(
    store: *DocumentStore,
    arena: *std.heap.ArenaAllocator,
    handle: *DocumentStore.Handle,
    tokenizer: *std.zig.Tokenizer,
    bound_type_params: *analysis.BoundTypeParams,
) !?analysis.DeclWithHandle {
    var current_type = analysis.TypeWithHandle.typeVal(.{
        .node = 0,
        .handle = handle,
    });

    var result: ?analysis.DeclWithHandle = null;

    while (true) {
        const tok = tokenizer.next();
        switch (tok.tag) {
            .eof => return result,
            .identifier => {
                if (try analysis.lookupSymbolGlobal(
                    store,
                    arena,
                    current_type.handle,
                    tokenizer.buffer[tok.loc.start..tok.loc.end],
                    0,
                )) |child| {
                    current_type = (try child.resolveType(store, arena, bound_type_params)) orelse return null;
                } else return null;
            },
            .period => {
                const after_period = tokenizer.next();
                switch (after_period.tag) {
                    .eof => return result,
                    .identifier => {
                        if (result) |child| {
                            current_type = (try child.resolveType(store, arena, bound_type_params)) orelse return null;
                        }
                        current_type = try analysis.resolveFieldAccessLhsType(store, arena, current_type, bound_type_params);

                        var current_type_node = switch (current_type.type.data) {
                            .other => |n| n,
                            else => return null,
                        };

                        var buf: [1]ast.Node.Index = undefined;
                        if (fnProto(current_type.handle.tree, current_type_node, &buf)) |func| {
                            // Check if the function has a body and if so, pass it
                            // so the type can be resolved if it's a generic function returning
                            // an anonymous struct
                            const has_body = current_type.handle.tree.nodes.items(.tag)[current_type_node] == .fn_decl;
                            const body = current_type.handle.tree.nodes.items(.data)[current_type_node].rhs;

                            if (try analysis.resolveReturnType(
                                store,
                                arena,
                                func,
                                current_type.handle,
                                bound_type_params,
                                if (has_body) body else null,
                            )) |ret| {
                                current_type = ret;
                                current_type_node = switch (current_type.type.data) {
                                    .other => |n| n,
                                    else => return null,
                                };
                            } else return null;
                        }

                        if (try analysis.lookupSymbolContainer(
                            store,
                            arena,
                            .{ .node = current_type_node, .handle = current_type.handle },
                            tokenizer.buffer[after_period.loc.start..after_period.loc.end],
                            true,
                        )) |child| {
                            result = child;
                        } else return null;
                    },
                    else => {
                        return null;
                    },
                }
            },
            else => {
                return null;
            },
        }
    }

    return result;
}

const cache_reload_command = ":reload-cached:";

pub const PrepareResult = struct {
    store: DocumentStore,
    root_handle: *DocumentStore.Handle,
    lib_uri: []const u8,

    pub fn deinit(self: *PrepareResult) void {
        self.store.allocator.free(self.lib_uri);
    }
};

pub fn prepare(gpa: *std.mem.Allocator, std_lib_path: []const u8) !PrepareResult {
    const resolved_lib_path = try std.fs.path.resolve(gpa, &[_][]const u8{std_lib_path});
    errdefer gpa.free(resolved_lib_path);
    std.debug.print("Library path: {s}\n", .{resolved_lib_path});

    var result: PrepareResult = undefined;
    try result.store.init(gpa, null, "", "", std_lib_path);
    errdefer result.store.deinit();

    result.lib_uri = try URI.fromPath(gpa, resolved_lib_path);
    errdefer gpa.free(result.lib_uri);

    result.root_handle = try result.store.openDocument("file://<ROOT>",
        \\const std = @import("std");
    );
    return result;
}

pub fn reloadCached(arena: *std.heap.ArenaAllocator, gpa: *std.mem.Allocator, prepared: *PrepareResult) !void {
    const initial_count = prepared.store.handles.count();
    var reloaded: usize = 0;
    var removals = std.ArrayList([]const u8).init(&arena.allocator);
    defer removals.deinit();
    var it = prepared.store.handles.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == prepared.root_handle) {
            continue;
        }

        // This was constructed from a path, it will never fail.
        const path = URI.parse(&arena.allocator, entry.key_ptr.*) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => unreachable,
        };

        const new_text = std.fs.cwd().readFileAllocOptions(gpa, path, std.math.maxInt(usize), null, @alignOf(u8), 0) catch |err| switch (err) {
            error.FileNotFound => {
                // prepared.store
                try removals.append(entry.key_ptr.*);
                continue;
            },
            else => |e| return e,
        };
        // Completely replace the whole text of the document
        gpa.free(entry.value_ptr.*.document.mem);
        entry.value_ptr.*.document.mem = new_text;
        entry.value_ptr.*.document.text = new_text;
        try prepared.store.refreshDocument(entry.value_ptr.*);

        reloaded += 1;
    }

    for (removals.items) |rm| {
        const entry = prepared.store.handles.getEntry(rm).?;
        entry.value_ptr.*.tree.deinit(gpa);
        prepared.store.allocator.free(entry.value_ptr.*.document.mem);

        for (entry.value_ptr.*.import_uris) |import_uri| {
            prepared.store.closeDocument(import_uri);
            prepared.store.allocator.free(import_uri);
        }
        prepared.store.allocator.free(entry.value_ptr.*.import_uris);
        entry.value_ptr.*.imports_used.deinit(prepared.store.allocator);
        entry.value_ptr.*.document_scope.deinit(prepared.store.allocator);
        prepared.store.allocator.destroy(entry.value_ptr.*);
        const uri_key = entry.key_ptr.*;
        std.debug.assert(prepared.store.handles.remove(rm));
        prepared.store.allocator.free(uri_key);
    }
    std.debug.print("Reloaded {d} of {d} cached documents, removed {d}.\n", .{
        reloaded,
        initial_count - 1,
        removals.items.len,
    });
}

pub fn dispose(prepared: *PrepareResult) void {
    prepared.store.deinit();
}

pub fn analyse(arena: *std.heap.ArenaAllocator, prepared: *PrepareResult, line: []const u8) !?[]const u8 {
    if (line[0] == '@') {
        for (builtins.builtins) |builtin| {
            if (std.mem.eql(u8, builtin.name, line)) {
                return try std.fmt.allocPrint(&arena.allocator, "https://ziglang.org/documentation/master/#{s}", .{line[1..]});
            }
        }
        return null;
    }

    var bound_type_params = analysis.BoundTypeParams.init(&arena.allocator);
    var tokenizer = std.zig.Tokenizer.init(try arena.allocator.dupeZ(u8, std.mem.trim(u8, line, "\n \t")));
    if (try getFieldAccessType(&prepared.store, arena, prepared.root_handle, &tokenizer, &bound_type_params)) |result| {
        if (result.handle != prepared.root_handle) {
            switch (result.decl.*) {
                .ast_node => |n| {
                    var handle = result.handle;
                    var node = n;
                    if (try analysis.resolveVarDeclAlias(
                        &prepared.store,
                        arena,
                        .{ .node = node, .handle = result.handle },
                    )) |alias_result| {
                        switch (alias_result.decl.*) {
                            .ast_node => |inner| {
                                handle = alias_result.handle;
                                node = inner;
                            },
                            else => {},
                        }
                    } else if (varDecl(result.handle.tree, node)) |vdecl| try_import_resolve: {
                        if (vdecl.ast.init_node != 0) {
                            const tree = result.handle.tree;
                            const node_tags = tree.nodes.items(.tag);
                            if (isBuiltinCall(tree, vdecl.ast.init_node)) {
                                const builtin_token = tree.nodes.items(.main_token)[vdecl.ast.init_node];
                                const call_name = tree.tokenSlice(builtin_token);

                                if (std.mem.eql(u8, call_name, "@import")) {
                                    const data = tree.nodes.items(.data)[vdecl.ast.init_node];
                                    const params = switch (node_tags[vdecl.ast.init_node]) {
                                        .builtin_call, .builtin_call_comma => tree.extra_data[data.lhs..data.rhs],
                                        .builtin_call_two, .builtin_call_two_comma => if (data.lhs == 0)
                                            &[_]ast.Node.Index{}
                                        else if (data.rhs == 0)
                                            &[_]ast.Node.Index{data.lhs}
                                        else
                                            &[_]ast.Node.Index{ data.lhs, data.rhs },
                                        else => unreachable,
                                    };
                                    if (params.len == 1) {
                                        const import_type = (try result.resolveType(
                                            &prepared.store,
                                            arena,
                                            &bound_type_params,
                                        )) orelse break :try_import_resolve;
                                        switch (import_type.type.data) {
                                            .other => |resolved_node| {
                                                handle = import_type.handle;
                                                node = resolved_node;
                                            },
                                            else => {},
                                        }
                                    }
                                }
                            }
                        }
                    }
                    const start_tok = if (analysis.getDocCommentTokenIndex(handle.tree, node)) |doc_comment|
                        doc_comment
                    else
                        handle.tree.firstToken(node);

                    const result_uri = handle.uri()[prepared.lib_uri.len..];
                    const start_loc = handle.tree.tokenLocation(0, start_tok);
                    const end_loc = handle.tree.tokenLocation(0, handle.tree.lastToken(node));

                    return try std.fmt.allocPrint(&arena.allocator, "https://github.com/ziglang/zig/blob/master/lib{s}#L{d}-L{d}\n", .{ result_uri, start_loc.line + 1, end_loc.line + 1 });
                },
                else => {},
            }
        }
    }
    return null;
}

pub fn main() anyerror!void {
    const gpa = std.heap.page_allocator;

    const reader = std.io.getStdIn().reader();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var args = std.process.args();
    _ = args.skip();
    const lib_path = try args.next(gpa) orelse return error.NoLibPathProvided;
    defer gpa.free(lib_path);

    var prepared = try prepare(gpa, lib_path);
    defer dispose(&prepared);

    var timer = try std.time.Timer.start();

    while (true) {
        defer {
            arena.deinit();
            arena.state.buffer_list = .{};
        }

        const line = reader.readUntilDelimiterAlloc(gpa, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        defer gpa.free(line);

        timer.reset();
        defer {
            std.debug.print("Took {} ns to complete request.\n", .{timer.lap()});
        }

        const trimmed_line = std.mem.trim(u8, line, "\n \t\r");
        if (trimmed_line.len == cache_reload_command.len and std.mem.eql(u8, trimmed_line, cache_reload_command)) {
            try reloadCached(&arena, gpa, &prepared);
            continue;
        }

        if (try analyse(&arena, &prepared, trimmed_line)) |match| {
            try std.io.getStdOut().writeAll("Match: ");
            try std.io.getStdOut().writeAll(match);
            try std.io.getStdOut().writer().writeByte('\n');
        } else {
            try std.io.getStdOut().writeAll("No match found.\n");
        }
    }
}
