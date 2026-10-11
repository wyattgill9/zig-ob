const std = @import("std");
const itch = @import("itch.zig");
const log = std.log.scoped(.book);

pub const Side = enum(u1) {
    bid,
    ask,

    fn fromIndicator(c: u8) !Side {
        return switch (c) {
            'B' => .bid,
            'S' => .ask,
            else => error.BadSide,
        };
    }
};

pub const Order = struct {
    id: u64,
    price: u32,
    remaining: u32,
    side: Side,
    timestamp: u48,
    mpid: ?[4]u8,
    node: std.DoublyLinkedList.Node = .{},
};

const Level = struct { price: u32, queue: std.DoublyLinkedList = .{} };

pub const OrderBook = struct {
    gpa: std.mem.Allocator,
    pool: std.heap.MemoryPool(Order) = .empty,
    orders: std.AutoHashMapUnmanaged(u64, *Order) = .empty,
    /// Per side, sorted so the best price is last: bids ascending, asks descending.
    // ponytail: sorted array of levels, O(levels) insert; fine for realistic depth, swap for a tree if profiling says so
    levels: [2]std.ArrayList(Level) = .{ .empty, .empty },

    pub fn init(gpa: std.mem.Allocator) OrderBook {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *OrderBook) void {
        self.pool.deinit(self.gpa);
        self.orders.deinit(self.gpa);
        for (&self.levels) |*l| l.deinit(self.gpa);
    }

    /// Parses and applies every message in `feed`; returns the message count.
    pub fn replay(self: *OrderBook, feed: []const u8) !usize {
        var rest = feed;
        var n: usize = 0;
        while (rest.len > 0) : (n += 1) {
            const r = try itch.parse(rest);
            try self.apply(r.msg);
            rest = rest[r.len..];
        }
        return n;
    }

    pub fn apply(self: *OrderBook, msg: itch.Message) !void {
        log.debug("{any}", .{msg});
        switch (msg) {
            inline .add_order, .add_order_mpid => |m, tag| try self.add(.{
                .id = m.order_ref,
                .price = m.price,
                .remaining = m.shares,
                .side = try .fromIndicator(m.side),
                .timestamp = m.header.timestamp,
                .mpid = if (tag == .add_order_mpid) m.mpid else null,
            }),
            inline .order_executed, .order_executed_with_price, .order_cancel => |m| try self.reduce(m.order_ref, m.shares),
            .order_delete => |m| try self.remove(m.order_ref),
            .order_replace => |m| {
                const old = (self.orders.get(m.order_ref) orelse return error.UnknownOrder).*;
                try self.remove(m.order_ref);
                try self.add(.{
                    .id = m.new_order_ref,
                    .price = m.price,
                    .remaining = m.shares,
                    .side = old.side,
                    .timestamp = m.header.timestamp,
                    .mpid = old.mpid,
                });
            },
            else => {},
        }
    }

    pub fn add(self: *OrderBook, order: Order) !void {
        if (self.orders.contains(order.id)) return error.DuplicateOrder;
        try self.orders.ensureUnusedCapacity(self.gpa, 1);
        const o = try self.pool.create(self.gpa);
        errdefer self.pool.destroy(o);
        o.* = order;
        const s = self.search(o.side, o.price);
        if (!s.found) try s.list.insert(self.gpa, s.i, .{ .price = o.price });
        s.list.items[s.i].queue.append(&o.node);
        self.orders.putAssumeCapacity(o.id, o);
    }

    /// Executes or cancels `shares`; the order leaves the book at zero.
    pub fn reduce(self: *OrderBook, id: u64, shares: u32) !void {
        const o = self.orders.get(id) orelse return error.UnknownOrder;
        if (shares > o.remaining) return error.Overfill;
        o.remaining -= shares;
        if (o.remaining == 0) try self.remove(id);
    }

    pub fn remove(self: *OrderBook, id: u64) !void {
        const o = (self.orders.fetchRemove(id) orelse return error.UnknownOrder).value;
        const s = self.search(o.side, o.price);
        const level = &s.list.items[s.i];
        level.queue.remove(&o.node);
        if (level.queue.first == null) _ = s.list.orderedRemove(s.i);
        self.pool.destroy(o);
    }

    pub fn best(self: *const OrderBook, side: Side) ?*Order {
        const level = self.levels[@intFromEnum(side)].getLastOrNull() orelse return null;
        return @fieldParentPtr("node", level.queue.first.?);
    }

    pub fn print(self: *const OrderBook, w: *std.Io.Writer) !void {
        for (self.levels, [_][]const u8{ "bids", "asks" }) |list, name| {
            try w.print("{s}:\n", .{name});
            for (0..list.items.len) |j| {
                const level = list.items[list.items.len - 1 - j];
                try w.print("  {d}.{d:0>4}\n", .{ level.price / 10_000, level.price % 10_000 });
                var it = level.queue.first;
                while (it) |node| : (it = node.next) {
                    const o: *Order = @fieldParentPtr("node", node);
                    try w.print("    #{d} x{d}\n", .{ o.id, o.remaining });
                }
            }
        }
    }

    fn search(self: *OrderBook, side: Side, price: u32) struct { list: *std.ArrayList(Level), i: usize, found: bool } {
        const Key = struct {
            side: Side,
            price: u32,
            fn order(k: @This(), l: Level) std.math.Order {
                const o = std.math.order(k.price, l.price);
                return if (k.side == .bid) o else o.invert();
            }
        };
        const list = &self.levels[@intFromEnum(side)];
        const i = std.sort.lowerBound(Level, list.items, Key{ .side = side, .price = price }, Key.order);
        return .{ .list = list, .i = i, .found = i < list.items.len and list.items[i].price == price };
    }
};

// sample.itch (order refs are base+n): A #0 bid 300@100, F #1 ask 400@101, A #2 bid 200@200,
// E #0 -100, C #2 -50, X #0 -150, U #1 -> #3 500@100.75, F #4 bid 1000@240, D #2, E #4 -300, X #4 -700.
test "replay sample feed" {
    const base = 0x0123456789ABCDEF;
    var book: OrderBook = .init(std.testing.allocator);
    defer book.deinit();
    try std.testing.expectEqual(11, try book.replay(@embedFile("data/sample.itch")));

    const bid = book.best(.bid).?;
    try std.testing.expectEqual(.{ base, 1_000_000, 50 }, .{ bid.id, bid.price, bid.remaining });
    const ask = book.best(.ask).?;
    try std.testing.expectEqual(.{ base + 3, 1_007_500, 500, [4]u8{ 'G', 'S', 'C', 'O' } }, .{ ask.id, ask.price, ask.remaining, ask.mpid.? });
    try std.testing.expectEqual(2, book.orders.count());
    try std.testing.expectEqual(.{ 1, 1 }, .{ book.levels[0].items.len, book.levels[1].items.len });
}

test "level ordering and overfill" {
    var book: OrderBook = .init(std.testing.allocator);
    defer book.deinit();
    for ([_]u32{ 5, 9, 7 }, 1..) |price, id| {
        try book.add(.{ .id = id, .price = price, .remaining = 10, .side = .bid, .timestamp = 0, .mpid = null });
        try book.add(.{ .id = id + 10, .price = price, .remaining = 10, .side = .ask, .timestamp = 0, .mpid = null });
    }
    try std.testing.expectEqual(9, book.best(.bid).?.price);
    try std.testing.expectEqual(5, book.best(.ask).?.price);
    try std.testing.expectError(error.Overfill, book.reduce(1, 11));
    try std.testing.expectError(error.DuplicateOrder, book.add(book.best(.bid).?.*));
    try book.reduce(2, 10);
    try std.testing.expectEqual(7, book.best(.bid).?.price);
}
