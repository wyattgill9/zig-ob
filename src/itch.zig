//! NASDAQ TotalView-ITCH 5.0 messages. Each payload struct lists its fields in
//! wire order; offsets and lengths are derived from the types at comptime.
//! Prices are Price(4) (dollars * 10_000) unless noted.
const std = @import("std");

pub const Header = struct { stock_locate: u16, tracking_number: u16, timestamp: u48 };
const Stock = [8]u8;

/// Enum value is the message type byte on the wire.
pub const Tag = enum(u8) {
    system_event = 'S',
    stock_directory = 'R',
    stock_trading_action = 'H',
    short_sale_price_test = 'Y',
    market_participant_position = 'L',
    mwcb_decline_level = 'V',
    mwcb_status = 'W',
    quoting_period_update = 'K',
    luld_auction_collar = 'J',
    operational_halt = 'h',
    add_order = 'A',
    add_order_mpid = 'F',
    order_executed = 'E',
    order_executed_with_price = 'C',
    order_cancel = 'X',
    order_delete = 'D',
    order_replace = 'U',
    trade = 'P',
    cross_trade = 'Q',
    broken_trade = 'B',
    noii = 'I',
    direct_listing = 'N',
};

pub const Message = union(Tag) {
    system_event: struct { header: Header, event_code: u8 },
    stock_directory: struct {
        header: Header,
        stock: Stock,
        market_category: u8,
        financial_status_indicator: u8,
        round_lot_size: u32,
        round_lots_only: u8,
        issue_classification: u8,
        issue_sub_type: [2]u8,
        authenticity: u8,
        short_sale_threshold_indicator: u8,
        ipo_flag: u8,
        luld_reference_price_tier: u8,
        etp_flag: u8,
        etp_leverage_factor: u32,
        inverse_indicator: u8,
    },
    stock_trading_action: struct { header: Header, stock: Stock, trading_state: u8, reserved: u8, reason: [4]u8 },
    short_sale_price_test: struct { header: Header, stock: Stock, reg_sho_action: u8 },
    market_participant_position: struct {
        header: Header,
        mpid: [4]u8,
        stock: Stock,
        primary_market_maker: u8,
        market_maker_mode: u8,
        market_participant_state: u8,
    },
    /// Price(8)
    mwcb_decline_level: struct { header: Header, level1: u64, level2: u64, level3: u64 },
    mwcb_status: struct { header: Header, breached_level: u8 },
    quoting_period_update: struct {
        header: Header,
        stock: Stock,
        ipo_quotation_release_time: u32,
        ipo_quotation_release_qualifier: u8,
        ipo_price: u32,
    },
    luld_auction_collar: struct {
        header: Header,
        stock: Stock,
        reference_price: u32,
        upper_price: u32,
        lower_price: u32,
        extension: u32,
    },
    operational_halt: struct { header: Header, stock: Stock, market_code: u8, action: u8 },
    add_order: struct { header: Header, order_ref: u64, side: u8, shares: u32, stock: Stock, price: u32 },
    add_order_mpid: struct { header: Header, order_ref: u64, side: u8, shares: u32, stock: Stock, price: u32, mpid: [4]u8 },
    order_executed: struct { header: Header, order_ref: u64, shares: u32, match_number: u64 },
    order_executed_with_price: struct {
        header: Header,
        order_ref: u64,
        shares: u32,
        match_number: u64,
        printable: u8,
        price: u32,
    },
    order_cancel: struct { header: Header, order_ref: u64, shares: u32 },
    order_delete: struct { header: Header, order_ref: u64 },
    order_replace: struct { header: Header, order_ref: u64, new_order_ref: u64, shares: u32, price: u32 },
    trade: struct { header: Header, order_ref: u64, side: u8, shares: u32, stock: Stock, price: u32, match_number: u64 },
    cross_trade: struct { header: Header, shares: u64, stock: Stock, price: u32, match_number: u64, cross_type: u8 },
    broken_trade: struct { header: Header, match_number: u64 },
    noii: struct {
        header: Header,
        paired_shares: u64,
        imbalance_shares: u64,
        imbalance_direction: u8,
        stock: Stock,
        far_price: u32,
        near_price: u32,
        reference_price: u32,
        cross_type: u8,
        price_variation_indicator: u8,
    },
    direct_listing: struct {
        header: Header,
        stock: Stock,
        open_eligibility_status: u8,
        min_price: u32,
        max_price: u32,
        near_execution_price: u32,
        near_execution_time: u64,
        lower_price_collar: u32,
        upper_price_collar: u32,
    },
};

/// Bytes `T` occupies on the wire.
pub fn wireSize(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .int => |i| i.bits / 8,
        .array => |a| a.len,
        .@"struct" => |s| comptime blk: {
            var n = 0;
            for (s.fields) |f| n += wireSize(f.type);
            break :blk n;
        },
        else => @compileError("unsupported wire type " ++ @typeName(T)),
    };
}

fn decode(comptime T: type, bytes: []const u8) T {
    switch (@typeInfo(T)) {
        .int => return std.mem.readInt(T, bytes[0..comptime wireSize(T)], .big),
        .array => return bytes[0..comptime wireSize(T)].*,
        .@"struct" => |s| {
            var out: T = undefined;
            comptime var off = 0;
            inline for (s.fields) |f| {
                @field(out, f.name) = decode(f.type, bytes[off..]);
                off += comptime wireSize(f.type);
            }
            return out;
        },
        else => @compileError("unsupported wire type " ++ @typeName(T)),
    }
}

/// Parses one message from the front of `buf`; `len` includes the type byte.
pub fn parse(buf: []const u8) error{ UnknownMessage, Truncated }!struct { msg: Message, len: usize } {
    if (buf.len == 0) return error.Truncated;
    const tag = std.enums.fromInt(Tag, buf[0]) orelse return error.UnknownMessage;
    switch (tag) {
        inline else => |t| {
            const T = @FieldType(Message, @tagName(t));
            const len = 1 + wireSize(T);
            if (buf.len < len) return error.Truncated;
            return .{ .msg = @unionInit(Message, @tagName(t), decode(T, buf[1..])), .len = len };
        },
    }
}

test "lengths match spec" {
    const spec = .{ .S = 12, .R = 39, .H = 25, .Y = 20, .L = 26, .V = 35, .W = 12, .K = 28, .J = 35, .h = 21, .A = 36, .F = 40, .E = 31, .C = 36, .X = 23, .D = 19, .U = 35, .P = 44, .Q = 40, .B = 19, .I = 50, .N = 48 };
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        const want = @field(spec, &[_]u8{f.value});
        try std.testing.expectEqual(want, 1 + wireSize(@FieldType(Message, f.name)));
    }
}

test "parse add order" {
    const bytes = [_]u8{'A'} ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0, 0x01, 0x02 } ++
        [_]u8{ 0, 0, 0, 0, 0, 0, 0, 7 } ++ "B".* ++ [_]u8{ 0, 0, 1, 0x2C } ++ "AAPL    ".* ++ [_]u8{ 0, 0x0F, 0x42, 0x40 };
    const r = try parse(&bytes);
    try std.testing.expectEqual(36, r.len);
    const a = r.msg.add_order;
    try std.testing.expectEqual(0x1234, a.header.stock_locate);
    try std.testing.expectEqual(0x0102, a.header.timestamp);
    try std.testing.expectEqual(7, a.order_ref);
    try std.testing.expectEqual('B', a.side);
    try std.testing.expectEqual(300, a.shares);
    try std.testing.expectEqualStrings("AAPL    ", &a.stock);
    try std.testing.expectEqual(1_000_000, a.price);
    try std.testing.expectError(error.Truncated, parse(bytes[0..35]));
    try std.testing.expectError(error.UnknownMessage, parse("Z"));
}
