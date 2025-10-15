const Self = @This();

const std = @import("std");
const allocator = std.heap.c_allocator;
const debug = std.debug;

const wlr = @import("wlroots");

const Output = @import("Output.zig");
const Toplevel = @import("Toplevel.zig");

width: i32 = 0,
height: i32 = 0,
horizontal_ratio: f64 = 2.0 / 3.0,
toplevels: std.ArrayList(*Toplevel) = .empty,
total_scale: f64 = 0.0,

pub fn len(self: Self) usize {
    return self.toplevels.items.len;
}

pub fn resize(self: *Self, width: i32, height: i32) void {
    self.width = width;
    self.height = height;
}

pub fn appendTile(self: *Self, toplevel: *Toplevel) !void {
    toplevel.index = self.len();
    try self.toplevels.append(allocator, toplevel);

    if (toplevel.index != 0) {
        self.total_scale += toplevel.scale;
    }
}

pub fn removeTile(self: *Self, to_remove: *Toplevel) void {
    for (to_remove.index..self.len() - 1) |i| {
        self.toplevels.items[i] = self.toplevels.items[i + 1];
        self.toplevels.items[i].index = i;
    }
    _ = self.toplevels.shrinkRetainingCapacity(self.len() - 1);

    if (to_remove.index == 0) {
        if (self.len() > 1) {
            self.total_scale -= self.toplevels.items[1].scale;
        }
    } else {
        self.total_scale -= to_remove.scale;
    }
}

pub fn resizeTile(self: Self, toplevel: *Toplevel, height: f64) void {
    debug.assert(toplevel != self.toplevels.getLast());

    const old_height = toplevel.height;
    toplevel.height = height;

    const next = self.toplevels[toplevel.index + 1];
    next.height -= height - old_height;
}

pub fn applyLayout(self: Self) void {
    const toplevels = self.toplevels.items;

    if (toplevels.len == 0) {
        return;
    }

    if (toplevels.len == 1) {
        const toplevel = self.toplevels.items[0];
        std.debug.assert(toplevel.index == 0);

        toplevel.setRect(0, 0, self.width, self.height);
        return;
    }

    const primary_x = 0;
    const primary_y = 0;
    const primary_width: u31 = @intFromFloat(
        @as(f64, @floatFromInt(self.width)) *
            self.horizontal_ratio,
    );
    const primary_height = self.height;

    const primary_toplevel = toplevels[0];
    std.debug.assert(primary_toplevel.index == 0);
    primary_toplevel.setRect(
        primary_x,
        primary_y,
        primary_width,
        primary_height,
    );

    const secondary_toplevels = toplevels[1..];

    const secondary_x = primary_x + primary_width + 1;
    const secondary_width = self.width - secondary_x;

    std.log.debug("{}", .{self.total_scale});

    var secondary_y: i32 = 0;
    for (secondary_toplevels, 0..) |toplevel, i| {
        std.debug.assert(toplevel.index == i + 1);

        const scale = toplevel.scale / self.total_scale;

        const secondary_height: i32 = if (i == self.len() - 2)
            primary_height - secondary_y
        else
            @intFromFloat(@as(
                f64,
                @floatFromInt(self.height),
            ) * scale);

        toplevel.setRect(
            @intCast(secondary_x),
            secondary_y,
            secondary_width,
            secondary_height,
        );
        secondary_y += secondary_height;
    }
}
