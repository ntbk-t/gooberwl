const Self = @This();

const std = @import("std");
const debug = std.debug;
const allocator = std.heap.c_allocator;

const wlr = @import("wlroots");

const Output = @import("Output.zig");
const Toplevel = @import("shells/Toplevel.zig");

width: i32 = 0,
height: i32 = 0,
horizontal_ratio: f64 = 2.0 / 3.0,
toplevels: std.ArrayList(*Toplevel) = .empty,
scroll: f64 = 0.0,
total_scale: f64 = 0.0,

pub fn len(self: Self) usize {
    return self.toplevels.items.len;
}

pub fn resize(self: *Self, width: i32, height: i32) void {
    self.width = width;
    self.height = height;
}

pub fn tileAt(self: *Self, x: f64, y: f64) ?*Toplevel {
    if (self.len() == 0) return null;

    if (x < self.horizontal_ratio * @as(f64, @floatFromInt(self.width))) {
        return self.toplevels.items[0];
    }

    var height: f64 = -self.scroll;
    for (self.toplevels.items[1..]) |toplevel| {
        const rect = toplevel.getRect();
        height += rect.height;

        if (y < height) {
            return toplevel;
        }
    }

    return null;
}

pub fn appendTile(self: *Self, toplevel: *Toplevel) !void {
    if (toplevel.scale == 0.0) {
        if (self.toplevels.items.len > 1) {
            toplevel.scale = self.toplevels.getLast().scale;
        } else {
            toplevel.scale = 1.0;
        }
    }

    toplevel.index = self.len();
    try self.toplevels.append(allocator, toplevel);

    if (toplevel.index != 0) {
        self.total_scale += toplevel.scale;
    }
}

pub fn removeTile(self: *Self, to_remove: *Toplevel) void {
    if (to_remove.index == 0) {
        if (self.len() > 1) {
            self.total_scale -= self.toplevels.items[1].scale;
        }
    } else {
        const next = self.toplevels.items[to_remove.index - 1];
        next.scale += to_remove.scale;
    }

    for (to_remove.index..self.len() - 1) |i| {
        self.toplevels.items[i] = self.toplevels.items[i + 1];
        self.toplevels.items[i].index = i;
    }
    _ = self.toplevels.shrinkRetainingCapacity(self.len() - 1);
}

pub fn swapTiles(self: Self, a: *Toplevel, b: *Toplevel) void {
    if (a == b) return;

    const a_index = a.index;
    const b_index = b.index;
    a.index = b_index;
    b.index = a_index;

    const a_scale = a.scale;
    const b_scale = b.scale;
    a.scale = b_scale;
    b.scale = a_scale;

    self.toplevels.items[a.index] = a;
    self.toplevels.items[b.index] = b;
}

pub fn resizeTile(self: Self, toplevel: *Toplevel, to_y: f64) void {
    const next = self.toplevels.items[toplevel.index + 1];
    const top: f64 = @floatFromInt(toplevel.scene_tree.node.y);
    const bottom = top + @as(
        f64,
        @floatFromInt(self.height),
    ) * toplevel.scale / self.total_scale;

    const resize_by = (to_y - bottom) * self.total_scale / @as(f64, @floatFromInt(self.height));

    toplevel.scale += resize_by;
    next.scale -= resize_by;
}

pub fn hide(self: Self) void {
    for (self.toplevels.items) |toplevel| {
        toplevel.setSize(0, 0);
        toplevel.scene_tree.node.setEnabled(false);
    }
}

pub fn applyLayout(self: Self) void {
    const toplevels = self.toplevels.items;

    if (toplevels.len == 0) {
        return;
    }

    if (toplevels.len == 1) {
        const toplevel = self.toplevels.items[0];
        debug.assert(toplevel.index == 0);

        if (!toplevel.managed) {
            toplevel.setRect(0, 0, self.width, self.height);
        }
        toplevel.scene_tree.node.setEnabled(true);
        return;
    }

    const primary_x = 0;
    const primary_y = 0;
    const primary_width: i32 = @intFromFloat(
        @as(f64, @floatFromInt(self.width)) *
            self.horizontal_ratio,
    );
    const primary_height = self.height;

    const primary_toplevel = toplevels[0];
    debug.assert(primary_toplevel.index == 0);
    primary_toplevel.scene_tree.node.setEnabled(true);
    if (!primary_toplevel.managed) {
        primary_toplevel.setRect(
            primary_x,
            primary_y,
            primary_width,
            primary_height,
        );
    }

    const secondary_toplevels = toplevels[1..];

    const secondary_x = primary_x + primary_width + 1;
    const secondary_width = self.width - secondary_x;

    var secondary_y: i32 = @intFromFloat(-self.scroll);
    for (secondary_toplevels, 0..) |toplevel, i| {
        toplevel.scene_tree.node.setEnabled(true);

        debug.assert(toplevel.index == i + 1);

        const scale = toplevel.scale / self.total_scale;

        const secondary_height: i32 = @max(if (i == self.len() - 2)
            primary_height - secondary_y
        else
            @as(i32, @intFromFloat(@as(
                f64,
                @floatFromInt(self.height),
            ) * scale)), toplevel.xdg_toplevel.current.min_height);

        if (!toplevel.managed) {
            toplevel.setRect(
                @intCast(secondary_x),
                secondary_y,
                secondary_width,
                secondary_height,
            );
        }
        secondary_y += secondary_height;
    }
}
