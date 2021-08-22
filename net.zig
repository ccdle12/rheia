const std = @import("std");
const sync = @import("sync.zig");
const runtime = @import("runtime.zig");

const io = std.io;
const ip = std.x.net.ip;
const fmt = std.fmt;
const mem = std.mem;
const tcp = std.x.net.tcp;
const math = std.math;
const time = std.time;

const assert = std.debug.assert;

const IPv4 = std.x.os.IPv4;
const IPv6 = std.x.os.IPv6;
const Context = runtime.Context;
const DoublyLinkedDeque = @import("intrusive.zig").DoublyLinkedDeque;
const DynamicRingBuffer = @import("ring_buffer.zig").DynamicRingBuffer;

pub fn parseIpAddress(address: []const u8) !ip.Address {
    const parsed = splitHostPort(address) catch |err| return switch (err) {
        error.DelimiterNotFound => ip.Address.initIPv4(IPv4.unspecified, try fmt.parseUnsigned(u16, address, 10)),
        else => err,
    };
    const parsed_host = parsed.host;
    const parsed_port = try fmt.parseUnsigned(u16, parsed.port, 10);
    if (parsed_host.len == 0) return ip.Address.initIPv4(IPv4.unspecified, parsed_port);

    for (parsed_host) |c| {
        switch (c) {
            '.' => return ip.Address{ .ipv4 = .{ .host = try IPv4.parse(parsed_host), .port = parsed_port } },
            ':' => return ip.Address{ .ipv6 = .{ .host = try IPv6.parse(parsed_host), .port = parsed_port } },
            else => {},
        }
    }

    return error.UnknownAddressProtocol;
}

pub const HostPort = struct {
    host: []const u8,
    port: []const u8,
};

pub fn splitHostPort(address: []const u8) !HostPort {
    var j: usize = 0;
    var k: usize = 0;

    const i = mem.lastIndexOfScalar(u8, address, ':') orelse return error.DelimiterNotFound;

    const host = parse: {
        if (address[0] == '[') {
            const end = mem.indexOfScalar(u8, address, ']') orelse return error.MissingEndBracket;
            if (end + 1 == i) {} else if (end + 1 == address.len) {
                return error.MissingRightBracket;
            } else {
                return error.MissingPort;
            }

            j = 1;
            k = end + 1;
            break :parse address[1..end];
        }

        if (mem.indexOfScalar(u8, address[0..i], ':') != null) {
            return error.TooManyColons;
        }
        break :parse address[0..i];
    };

    if (mem.indexOfScalar(u8, address[j..], '[') != null) {
        return error.UnexpectedLeftBracket;
    }
    if (mem.indexOfScalar(u8, address[k..], ']') != null) {
        return error.UnexpectedRightBracket;
    }

    const port = address[i + 1 ..];

    return HostPort{ .host = host, .port = port };
}

pub fn hashIpAddress(address: ip.Address) u64 {
    var hasher = std.hash.Wyhash.init(0);
    switch (address) {
        .ipv4 => |ipv4| {
            hasher.update(&ipv4.host.octets);
            hasher.update(mem.asBytes(&ipv4.port));
        },
        .ipv6 => |ipv6| {
            hasher.update(&ipv6.host.octets);
            hasher.update(mem.asBytes(&ipv6.host.scope_id));
            hasher.update(mem.asBytes(&ipv6.port));
        },
    }
    return hasher.final();
}

pub fn eqlIpAddress(a: ip.Address, b: ip.Address) bool {
    switch (a) {
        .ipv4 => {
            if (b != .ipv4) return false;
            if (a.ipv4.port != b.ipv4.port) return false;
            if (!a.ipv4.host.eql(b.ipv4.host)) return false;
        },
        .ipv6 => {
            if (b != .ipv6) return false;
            if (a.ipv6.port != b.ipv6.port) return false;
            if (!a.ipv6.host.eql(b.ipv6.host)) return false;
        },
    }
    return true;
}

pub const Packet = struct {
    pub const max_size = 1 * 1024 * 1024;
    pub const size = @sizeOf(u32) + @sizeOf(u32) + @sizeOf(Packet.Op) + @sizeOf(Packet.Tag);

    pub const Op = enum(u8) {
        command,
        request,
        response,
    };

    pub const Tag = enum(u8) {
        ping,
        hello,
        find_node,
        push_transaction,
        pull_transaction,
        pull_block,
    };

    len: u32,
    nonce: u32,
    op: Op,
    tag: Tag,

    pub fn write(self: Packet, writer: anytype) !void {
        try writer.writeIntLittle(u32, self.len);
        try writer.writeIntLittle(u32, self.nonce);
        try writer.writeIntLittle(u8, @enumToInt(self.op));
        try writer.writeIntLittle(u8, @enumToInt(self.tag));
    }

    pub fn read(reader: anytype) !Packet {
        const len = try reader.readIntLittle(u32);
        if (len > Packet.max_size) return error.FrameTooLarge;

        const nonce = try reader.readIntLittle(u32);
        const op = try reader.readEnum(Packet.Op, .Little);
        const tag = try reader.readEnum(Packet.Tag, .Little);

        return Packet{ .len = len, .nonce = nonce, .op = op, .tag = tag };
    }
};

pub const Client = struct {
    const log = std.log.scoped(.client);

    pub const CircuitBreaker = struct {
        pub const Params = struct {
            state: State = .open,
            max_allowed_failed_attempts: u64 = 10,
            reset_timeout_period: i64 = 30_000,
        };

        pub const State = enum { open, half_open, closed };

        num_failed_attempts: u64,
        last_time_attempt_failed: i64,

        max_allowed_failed_attempts: u64,
        reset_timeout_period: i64,

        pub fn init(params: CircuitBreaker.Params) CircuitBreaker {
            assert(params.max_allowed_failed_attempts > 0);
            assert(params.reset_timeout_period > 0);

            const num_failed_attempts: u64 = switch (params.state) {
                .open, .half_open => math.maxInt(u64),
                .closed => 0,
            };

            const last_time_attempt_failed: i64 = switch (params.state) {
                .open => math.maxInt(i64),
                .half_open, .closed => 0,
            };

            return CircuitBreaker{
                .num_failed_attempts = num_failed_attempts,
                .last_time_attempt_failed = last_time_attempt_failed,
                .max_allowed_failed_attempts = params.max_allowed_failed_attempts,
                .reset_timeout_period = params.reset_timeout_period,
            };
        }

        pub fn reportSuccess(self: *CircuitBreaker) void {
            self.num_failed_attempts = 0;
            self.last_time_attempt_failed = 0;
        }

        pub fn reportFailure(self: *CircuitBreaker, current_time: i64) void {
            self.num_failed_attempts = math.add(u64, self.num_failed_attempts, 1) catch self.num_failed_attempts;
            self.last_time_attempt_failed = current_time;
        }

        pub fn getState(self: CircuitBreaker, current_time: i64) CircuitBreaker.State {
            if (self.num_failed_attempts <= self.max_allowed_failed_attempts) {
                return .closed;
            }
            if (math.sub(i64, current_time, self.last_time_attempt_failed) catch 0 > self.reset_timeout_period) {
                return .half_open;
            }
            return .open;
        }

        pub fn hasFailuresReported(self: CircuitBreaker) bool {
            return self.num_failed_attempts > 0 and self.last_time_attempt_failed > 0;
        }
    };

    pub const RPC = struct {
        pub const Response = struct {
            header: Packet,
            body: []const u8,

            pub fn deinit(self: RPC.Response, gpa: *mem.Allocator) void {
                gpa.free(self.body);
            }
        };

        pub const Entry = struct {
            parker: sync.Parker(RPC.Response) = .{},
            response: @Frame(sync.Parker(RPC.Response).park) = undefined,
        };

        pending: DynamicRingBuffer(?*RPC.Entry, u32),
        request_parker: sync.Parker(void) = .{},

        pub fn init(gpa: *mem.Allocator, capacity: usize) !RPC {
            const pending = try DynamicRingBuffer(?*RPC.Entry, u32).initCapacity(gpa, capacity);
            mem.set(?*RPC.Entry, pending.entries, null);
            return RPC{ .pending = pending };
        }

        pub fn deinit(self: *RPC, gpa: *mem.Allocator) void {
            self.pending.deinit(gpa);
        }

        pub fn register(self: *RPC, ctx: *Context, entry: *RPC.Entry) !u32 {
            const nonce = nonce: {
                while (self.pending.count() == self.pending.entries.len) {
                    try self.request_parker.park(ctx);
                }
                break :nonce self.pending.head;
            };

            self.pending.push(entry);

            var callback: struct {
                state: Context.Callback = .{ .run = @This().run },
                self: *RPC,
                nonce: u32,

                pub fn run(state: *Context.Callback) void {
                    const callback = @fieldParentPtr(@This(), "state", state);
                    callback.self.pending.entries[callback.nonce & (callback.self.pending.entries.len - 1)] = null;
                    callback.self.shiftForwards();
                }
            } = .{ .self = self, .nonce = nonce };

            try ctx.register(&callback.state);
            defer ctx.deregister(&callback.state);

            entry.response = async entry.parker.park(ctx);

            return nonce;
        }

        pub fn push(self: *RPC, response: RPC.Response) bool {
            const distance = response.header.nonce -% self.pending.tail;
            if (distance >= self.pending.entries.len) return false;

            const index = response.header.nonce & (self.pending.entries.len - 1);
            const entry = self.pending.entries[index] orelse return false;
            self.pending.entries[index] = null;
            self.shiftForwards();

            entry.parker.notify(response);

            return true;
        }

        fn shiftForwards(self: *RPC) void {
            while (self.pending.tail != self.pending.head and self.pending.entries[self.pending.tail & (self.pending.entries.len - 1)] == null) {
                self.pending.tail +%= 1;
                self.request_parker.notify({});
            }
        }
    };

    pub const Connection = struct {
        id: usize,
        frame: @Frame(Client.serveConnection),
    };

    ctx: Context = .{},
    address: ip.Address,
    buffer: std.ArrayList(u8),

    rpc: RPC,
    id: usize = 0,
    alive: usize = 0,
    capacity: usize = 4,
    wg: sync.WaitGroup = .{},

    connect_attempt: sync.Mutex = .{},
    connect_parker: sync.Parker(anyerror!void) = .{},
    breaker: CircuitBreaker = CircuitBreaker.init(.{ .state = .half_open }),

    write_parker: sync.Parker(void) = .{},
    writer_parker: sync.Parker(void) = .{},

    pub fn init(gpa: *mem.Allocator, address: ip.Address) !Client {
        return Client{
            .address = address,
            .buffer = std.ArrayList(u8).init(gpa),
            .rpc = try RPC.init(gpa, 65536),
        };
    }

    pub fn deinit(self: *Client, gpa: *mem.Allocator, ctx: *Context) !void {
        self.ctx.cancel();
        try self.wg.wait(ctx);
        self.rpc.deinit(gpa);
        self.buffer.deinit();
    }

    pub fn acquireWriter(self: *Client, ctx: *Context, gpa: *mem.Allocator) !std.ArrayList(u8).Writer {
        try self.ensureConnectionAvailable(ctx, gpa);

        while (self.buffer.items.len > 65536) {
            try self.write_parker.park(ctx);

            if (self.ctx.cancelled) {
                return error.Closed;
            }
        }

        return self.buffer.writer();
    }

    pub fn releaseWriter(self: *Client, _: std.ArrayList(u8).Writer) void {
        self.writer_parker.notify({});
    }

    pub fn ensureConnectionAvailable(self: *Client, ctx: *Context, gpa: *mem.Allocator) !void {
        if (self.ctx.cancelled) return error.Closed;

        if (self.wg.len == 0 or (!self.breaker.hasFailuresReported() and self.buffer.items.len > 0 and self.wg.len < self.capacity)) {
            log.debug("{} [{}] was spawned", .{ self.address, self.id });

            const conn = try gpa.create(Client.Connection);
            conn.* = .{ .id = self.id, .frame = undefined };
            conn.frame = async self.serveConnection(gpa, conn);
            self.id +%= 1;
        }

        if (self.alive > 0) return;

        return try self.connect_parker.park(ctx);
    }

    fn serveConnection(self: *Client, gpa: *mem.Allocator, conn: *Client.Connection) !void {
        self.wg.add(1);

        defer {
            log.debug("{} [{}] disconnected", .{ self.address, conn.id });
            suspend self.closeConnection(gpa, conn);
        }

        while (true) {
            const client = self.attemptConnection(&self.ctx, conn) catch |err| {
                if (self.ctx.cancelled or self.wg.len > 1) {
                    return;
                }
                if (err == error.CircuitBreakerTripped) {
                    log.debug("{} [{}] reported connection error: {}", .{
                        self.address,
                        conn.id,
                        err,
                    });
                    return self.connect_parker.broadcast(err);
                }
                continue;
            };
            defer client.deinit();

            var callback: struct {
                state: Context.Callback = .{ .run = @This().run },
                client: tcp.Client,

                pub fn run(state: *Context.Callback) void {
                    const callback = @fieldParentPtr(@This(), "state", state);
                    callback.client.shutdown(.recv) catch {};
                }
            } = .{ .client = client };

            try self.ctx.register(&callback.state);
            defer self.ctx.deregister(&callback.state);

            self.alive += 1;
            defer self.alive -= 1;

            self.connect_parker.broadcast({});

            var ctx: Context = .{};
            var writer_frame = async self.runWriteLoop(&ctx, gpa, client);
            var reader_frame = async self.runReadLoop(&ctx, gpa, client);

            await reader_frame catch {};
            ctx.cancel();
            await writer_frame catch {};

            if (self.ctx.cancelled or self.wg.len > 1) {
                return;
            }
        }
    }

    fn runWriteLoop(self: *Client, ctx: *Context, gpa: *mem.Allocator, client: tcp.Client) !void {
        _ = gpa;

        var stream: runtime.Stream = .{ .socket = client.socket, .context = ctx };
        var writer = stream.writer();

        while (true) {
            while (self.buffer.items.len == 0) {
                try self.writer_parker.park(ctx);
            }

            const buffer = self.buffer.toOwnedSlice();
            defer gpa.free(buffer);

            try writer.writeAll(buffer);
            self.write_parker.notify({});
        }
    }

    fn runReadLoop(self: *Client, ctx: *Context, gpa: *mem.Allocator, client: tcp.Client) !void {
        var stream: runtime.Stream = .{ .socket = client.socket, .context = ctx };
        var reader = stream.reader();

        var buffer = std.fifo.LinearFifo(u8, .Dynamic).init(gpa);
        defer buffer.deinit();

        while (true) {
            while (buffer.count < Packet.size) {
                const num_bytes = try reader.read(try buffer.writableWithSize(65536));
                if (num_bytes == 0) return;
                buffer.update(num_bytes);
            }

            const packet = try Packet.read(buffer.reader());

            while (buffer.count < packet.len) {
                const num_bytes = try reader.read(try buffer.writableWithSize(65536));
                if (num_bytes == 0) return;
                buffer.update(num_bytes);
            }

            const frame = try gpa.alloc(u8, packet.len);
            errdefer gpa.free(frame);

            try buffer.reader().readNoEof(frame);

            if (packet.op == .response) {
                if (!self.rpc.push(.{ .header = packet, .body = frame })) {
                    return error.UnexpectedResponse;
                }
                continue;
            }

            gpa.free(frame);
        }
    }

    fn attemptConnection(self: *Client, ctx: *Context, conn: *Client.Connection) !tcp.Client {
        try self.connect_attempt.acquire(ctx);
        defer self.connect_attempt.release();

        if (self.breaker.getState(time.milliTimestamp()) == .open) {
            return error.CircuitBreakerTripped;
        }

        if (self.breaker.hasFailuresReported()) {
            const delay_max: i64 = 3000 * time.ns_per_ms;
            const delay_step: i64 = 10 * time.ns_per_ms;
            const delay = math.min(delay_max, delay_step * math.shl(i64, 1, self.breaker.num_failed_attempts - 1));

            log.debug("{} [{}] attempt #{}: will attempt to reconnect in {} milliseconds", .{
                self.address,
                conn.id,
                self.breaker.num_failed_attempts,
                @divTrunc(delay, time.ns_per_ms),
            });

            try runtime.timeout(ctx, .{ .nanoseconds = delay });
        }

        errdefer |err| {
            log.debug("{} [{}] failed to establish a connection: {}", .{ self.address, conn.id, err });
            self.breaker.reportFailure(time.milliTimestamp());
        }

        const client = try tcp.Client.init(.ip, .{ .close_on_exec = true });
        errdefer client.deinit();

        try client.setNoDelay(true);
        try client.setKeepAlive(true);
        try client.setQuickACK(true);

        try runtime.connect(ctx, client.socket, self.address.into());

        log.debug("{} [{}] successfully established a connection", .{ self.address, conn.id });
        self.breaker.reportSuccess();

        return client;
    }

    fn closeConnection(self: *Client, gpa: *mem.Allocator, conn: *Client.Connection) void {
        gpa.destroy(conn);
        self.wg.sub(1);
    }
};

pub fn Server(comptime Node: type) type {
    return struct {
        const log = std.log.scoped(.server);

        const Self = @This();

        pub const Connection = struct {
            client: tcp.Client,
            buffer: std.ArrayList(u8),
            write_parker: sync.Parker(void) = .{},
            writer_parker: sync.Parker(void) = .{},
        };

        wg: sync.WaitGroup = .{},
        node: *Node,

        pub fn init(node: *Node) Self {
            return Self{ .node = node };
        }

        pub fn deinit(self: *Self, ctx: *Context) !void {
            try self.wg.wait(ctx);
        }

        pub fn serve(self: *Self, ctx: *Context, gpa: *mem.Allocator, listener: tcp.Listener) !void {
            const bind_address = try listener.getLocalAddress();

            log.info("listening for peers: {}", .{bind_address});
            defer log.info("stopped listening for peers: {}", .{bind_address});

            var callback: struct {
                state: Context.Callback = .{ .run = @This().run },
                listener: tcp.Listener,

                pub fn run(state: *Context.Callback) void {
                    const callback = @fieldParentPtr(@This(), "state", state);
                    return callback.listener.shutdown() catch {};
                }
            } = .{ .listener = listener };

            try ctx.register(&callback.state);
            defer ctx.deregister(&callback.state);

            while (true) {
                self.acceptConnection(ctx, gpa, listener) catch |err| {
                    switch (err) {
                        error.Cancelled, error.SocketNotListening => break,
                        error.OutOfMemory, error.Temporary => continue,
                        else => return err,
                    }
                };
            }
        }

        fn acceptConnection(self: *Self, ctx: *Context, gpa: *mem.Allocator, listener: tcp.Listener) !void {
            const conn = tcp.Connection.from(try runtime.accept(ctx, listener.socket, .{ .close_on_exec = true }));
            errdefer conn.client.deinit();

            try conn.client.setNoDelay(true);
            try conn.client.setKeepAlive(true);
            try conn.client.setQuickACK(true);

            const frame = try gpa.create(@Frame(Self.serveConnection));
            errdefer gpa.destroy(frame);

            frame.* = async self.serveConnection(ctx, gpa, conn);
        }

        fn closeConnection(self: *Self, gpa: *mem.Allocator, frame: *@Frame(Self.serveConnection)) void {
            gpa.destroy(frame);
            self.wg.sub(1);
        }

        fn serveConnection(self: *Self, ctx: *Context, gpa: *mem.Allocator, conn: tcp.Connection) !void {
            self.wg.add(1);

            defer {
                conn.deinit();
                suspend self.closeConnection(gpa, @frame());
            }

            log.info("new peer connected: {}", .{conn.address});
            defer log.info("peer disconnected: {}", .{conn.address});

            var callback = struct {
                state: Context.Callback = .{ .run = @This().run },
                client: tcp.Client,

                pub fn run(state: *Context.Callback) void {
                    const callback = @fieldParentPtr(@This(), "state", state);
                    callback.client.shutdown(.recv) catch {};
                }
            }{ .client = conn.client };

            try ctx.register(&callback.state);
            defer ctx.deregister(&callback.state);

            var server_conn: Self.Connection = .{
                .client = conn.client,
                .buffer = std.ArrayList(u8).init(gpa),
            };
            defer server_conn.buffer.deinit();

            var child_ctx: Context = .{};
            var writer_frame = async self.runWriteLoop(&child_ctx, gpa, &server_conn);
            var reader_frame = async self.runReadLoop(&child_ctx, gpa, &server_conn);

            await reader_frame catch {};
            child_ctx.cancel();
            await writer_frame catch {};
        }

        fn runReadLoop(self: *Self, ctx: *Context, gpa: *mem.Allocator, conn: *Self.Connection) !void {
            var stream: runtime.Stream = .{ .socket = conn.client.socket, .context = ctx };
            var reader = stream.reader();

            var buffer = std.fifo.LinearFifo(u8, .Dynamic).init(gpa);
            defer buffer.deinit();

            while (true) {
                while (buffer.count < Packet.size) {
                    const num_bytes = try reader.read(try buffer.writableWithSize(65536));
                    if (num_bytes == 0) return;
                    buffer.update(num_bytes);
                }

                const packet = try Packet.read(buffer.reader());

                while (buffer.count < packet.len) {
                    const num_bytes = try reader.read(try buffer.writableWithSize(65536));
                    if (num_bytes == 0) return;
                    buffer.update(num_bytes);
                }

                var frame = io.limitedReader(buffer.reader(), packet.len);

                while (conn.buffer.items.len > 65536) {
                    try conn.write_parker.park(ctx);
                }

                try self.node.handleServerPacket(ctx, gpa, conn, packet, &frame);
            }
        }

        fn runWriteLoop(self: *Self, ctx: *Context, gpa: *mem.Allocator, conn: *Self.Connection) !void {
            _ = self;
            _ = gpa;

            var stream: runtime.Stream = .{ .socket = conn.client.socket, .context = ctx };
            var writer = stream.writer();

            while (true) {
                while (conn.buffer.items.len == 0) {
                    try conn.writer_parker.park(ctx);
                }

                try writer.writeAll(conn.buffer.items);
                conn.buffer.clearRetainingCapacity();
                conn.write_parker.notify({});
            }
        }
    };
}
