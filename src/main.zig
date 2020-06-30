const std = @import("std");
const analysis = @import("analysis.zig");
const DocumentStore = @import("document_store.zig");
const URI = @import("uri.zig");
const ast = std.zig.ast;

pub fn getFieldAccessType(
    store: *DocumentStore,
    arena: *std.heap.ArenaAllocator,
    handle: *DocumentStore.Handle,
    tokenizer: *std.zig.Tokenizer,
) !?analysis.TypeWithHandle {
    var current_type = analysis.TypeWithHandle.typeVal(.{
        .node = &handle.tree.root_node.base,
        .handle = handle,
    });

    var bound_type_params = analysis.BoundTypeParams.init(&arena.allocator);
    while (true) {
        const tok = tokenizer.next();
        switch (tok.id) {
            .Eof => return try analysis.resolveFieldAccessLhsType(store, arena, current_type, &bound_type_params),
            .Identifier => {
                if (try analysis.lookupSymbolGlobal(store, arena, current_type.handle, tokenizer.buffer[tok.loc.start..tok.loc.end], 0)) |child| {
                    current_type = (try child.resolveType(store, arena, &bound_type_params)) orelse return null;
                } else return null;
            },
            .Period => {
                const after_period = tokenizer.next();
                switch (after_period.id) {
                    .Eof => return try analysis.resolveFieldAccessLhsType(store, arena, current_type, &bound_type_params),
                    .Identifier => {
                        current_type = try analysis.resolveFieldAccessLhsType(store, arena, current_type, &bound_type_params);

                        var current_type_node = switch (current_type.type.data) {
                            .other => |n| n,
                            else => return null,
                        };

                        if (current_type_node.cast(ast.Node.FnProto)) |func| {
                            if (try analysis.resolveReturnType(store, arena, func, current_type.handle, &bound_type_params)) |ret| {
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
                            !current_type.type.is_type_val,
                        )) |child| {
                            current_type = (try child.resolveType(store, arena, &bound_type_params)) orelse return null;
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

    return try analysis.resolveFieldAccessLhsType(store, arena, current_type, &bound_type_params);
}

pub fn main() anyerror!void {
    const gpa = std.heap.page_allocator;

    const reader = std.io.getStdIn().reader();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var args = try std.process.argsWithAllocator(&arena.allocator);
    defer arena.deinit();

    _ = args.skip();
    const lib_path = try args.next(&arena.allocator) orelse return error.NoLibPathProvided;
    const resolved_lib_path = try std.fs.path.resolve(&arena.allocator, &[_][]const u8{lib_path});
    std.debug.print("Library path: {}\n", .{resolved_lib_path});
    const lib_uri = try URI.fromPath(gpa, resolved_lib_path);

    var doc_store: DocumentStore = undefined;
    try doc_store.init(gpa, null, "", lib_path);
    defer doc_store.deinit();

    const root_handle = try doc_store.openDocument("file://<ROOT>",
        \\const std = @import("std");
    );

    var timer = try std.time.Timer.start();

    while (true) {
        const line = reader.readUntilDelimiterAlloc(gpa, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        defer gpa.free(line);

        timer.reset();
        defer {
            std.debug.print("Took {} ns to complete request.\n", .{timer.lap()});
        }

        var tokenizer = std.zig.Tokenizer.init(line);
        if (try getFieldAccessType(&doc_store, &arena, root_handle, &tokenizer)) |result| {
            if (result.handle != root_handle) {
                const result_uri = result.handle.uri()[lib_uri.len..];
                switch (result.type.data) {
                    .other => |n| {
                        const start_tok = if (analysis.getDocCommentNode(result.handle.tree, n)) |doc_comment|
                            doc_comment.first_line
                        else
                            n.firstToken();

                        const start_loc = result.handle.tree.tokenLocation(0, start_tok);
                        const end_loc = result.handle.tree.tokenLocation(0, n.lastToken());
                        const github_uri = try std.fmt.allocPrint(&arena.allocator, "https://github.com/ziglang/zig/blob/master/lib{}#L{}-L{}\n", .{ result_uri, start_loc.line + 1, end_loc.line + 1 });
                        try std.io.getStdOut().writeAll(github_uri);
                    },
                    else => {},
                }
            }
        }

        arena.deinit();
        arena.state.buffer_list = .{};
    }
}
