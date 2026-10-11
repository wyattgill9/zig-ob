const std = @import("std");
const OrderBook = @import("book.zig").OrderBook;

/// Set `.book` to `.debug` to trace every applied message.
pub const std_options: std.Options = .{ .log_scope_levels = &.{.{ .scope = .book, .level = .info }} };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const path = if (args.len > 1) args[1] else "src/data/sample.itch";
    const feed = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited);

    var book: OrderBook = .init(init.gpa);
    defer book.deinit();
    const n = try book.replay(feed);

    var buf: [4096]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    try out.interface.print("{d} messages\n", .{n});
    try book.print(&out.interface);
    try out.interface.flush();
}

test {
    _ = @import("book.zig");
    _ = @import("itch.zig");
}
