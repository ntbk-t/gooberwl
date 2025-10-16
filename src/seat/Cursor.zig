const Self = @This();

const std = @import("std");
const log = std.log;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Seat = @import("Seat.zig");
const Server = @import("../Server.zig");

wlr_cursor: *wlr.Cursor,
mode: enum { passthrough, move, resize } = .passthrough,
resize_edges: wlr.Edges = .{},
click_serial: u32 = 0,

on_cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(onMotion),
on_cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(onMotionAbsolute),
on_cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(onButton),
on_cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(onAxis),
on_cursor_frame: wl.Listener(*wlr.Cursor) = .init(onFrame),

pub fn getSeat(self: *Self) *Seat {
    return @fieldParentPtr("cursor", self);
}

fn onMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const self: *Self = @fieldParentPtr("on_motion", listener);
    self.wlr_cursor.move(event.device, event.delta_x, event.delta_y);
    self.processMotion(event.time_msec);
}

fn onMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const self: *Self = @fieldParentPtr("on_motion_absolute", listener);
    self.wlr_cursor.warpAbsolute(event.device, event.x, event.y);
    self.processMotion(event.time_msec);
}

fn onButton(
    listener: *wl.Listener(*wlr.Pointer.event.Button),
    event: *wlr.Pointer.event.Button,
) void {
    const self: *Self = @fieldParentPtr("on_button", listener);
    const seat = self.getSeat();

    const serial = seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    switch (event.state) {
        .pressed => {
            self.click_serial = serial;
            if (self.viewAt(self.cursor.x, self.cursor.y)) |res| {
                self.focusView(res.toplevel);
            }
        },
        .released => {
            switch (self.cursor_mode) {
                .passthrough => {},
                .move => self.processMove(),
                .resize => self.cursor_mode = .passthrough,
            }
            self.cursor_mode = .passthrough;
        },
        _ => {},
    }
}

fn onAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const self: *Self = @fieldParentPtr("cursor_axis", listener);
    self.seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
        event.relative_direction,
    );
}

fn onFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const self: *Self = @fieldParentPtr("cursor_frame", listener);
    self.seat.pointerNotifyFrame();
}

fn processMotion(self: *Self, time_msec: u32) void {
    switch (self.cursor_mode) {
        .passthrough => self.processPassthrough(time_msec),
        .resize => self.processResize(),
        .move => {},
    }
}

fn processPassthrough(self: *Self, time_msec: u32) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    if (server.viewAt(self.cursor.x, self.cursor.y)) |res| {
        seat.wlr_seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
        seat.wlr_seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
    } else {
        self.wlr_cursor.setXcursor(server.cursor_mgr, "default");
        seat.wlr_seat.pointerClearFocus();
    }
}

fn processResize(self: *Self) void {
    const toplevel = self.focused_toplevel orelse {
        std.log.warn("cursor mode set to resize, but no toplevel is focused!", .{});
        self.cursor_mode = .passthrough;
        return;
    };

    const output = self.output_layout.outputAt(self.cursor.x, self.cursor.y) orelse return;
    var layout_dirty = false;

    if ((toplevel.index != 0 and self.resize_edges.left) or
        (toplevel.index == 0 and self.resize_edges.right))
    {
        toplevel.getWorkspace().horizontal_ratio = self.cursor.x / @as(f64, @floatFromInt(output.width));
        layout_dirty = true;
    }

    if (toplevel.index > 1 and self.resize_edges.top) {
        const prev = toplevel.getWorkspace().toplevels.items[toplevel.index - 1];
        prev.getWorkspace().resizeTile(prev, self.cursor.y);
        layout_dirty = true;
    }

    if (toplevel.index != 0 and
        toplevel.index != self.toplevels.items.len - 1 and
        self.resize_edges.bottom)
    {
        toplevel.getWorkspace().resizeTile(toplevel, self.cursor.y);
        layout_dirty = true;
    }

    if (layout_dirty == true) {
        self.applyWorkspaceLayout(toplevel.workspace_id);
    }
}
