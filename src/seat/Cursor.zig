const Self = @This();

const std = @import("std");
const log = std.log;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Seat = @import("Seat.zig");
const Server = @import("../Server.zig");
const Toplevel = @import("../shells/Toplevel.zig");

const State = union(enum) {
    passthrough: Passthrough,
    move: Move,
    resize: Resize,

    const Passthrough = void;
    const Move = struct {
        toplevel: *Toplevel,
        x_offset: f64,
        y_offset: f64,
    };
    const Resize = struct {
        toplevel: *Toplevel,
        edges: wlr.Edges,
        x_offset: f64,
        y_offset: f64,
    };
};

wlr_cursor: *wlr.Cursor,
attached_devices: usize = 0,
state: State = .{ .passthrough = {} },
resize_edges: wlr.Edges = .{},
click_serial: u32 = 0,

on_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(onMotion),
on_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(onMotionAbsolute),
on_button: wl.Listener(*wlr.Pointer.event.Button) = .init(onButton),
on_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(onAxis),
on_frame: wl.Listener(*wlr.Cursor) = .init(onFrame),

pub fn init() !Self {
    return .{ .wlr_cursor = try wlr.Cursor.create() };
}

pub fn start(self: *Self) void {
    self.wlr_cursor.events.motion.add(&self.on_motion);
    self.wlr_cursor.events.motion_absolute.add(&self.on_motion_absolute);
    self.wlr_cursor.events.button.add(&self.on_button);
    self.wlr_cursor.events.axis.add(&self.on_axis);
    self.wlr_cursor.events.frame.add(&self.on_frame);
}

pub fn deinit(self: *Self) void {
    self.on_motion.link.remove();
    self.on_motion_absolute.link.remove();
    self.on_button.link.remove();
    self.on_axis.link.remove();
    self.on_frame.link.remove();
}

pub fn getSeat(self: *Self) *Seat {
    return @fieldParentPtr("cursor", self);
}

pub fn addInput(self: *Self, device: *wlr.InputDevice) void {
    self.wlr_cursor.attachInputDevice(device);
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
    const server = seat.getServer();
    const output = server.getOutputAtCursor() orelse return;

    switch (event.state) {
        .pressed => {
            if (seat.wlr_seat.getKeyboard()) |keyboard| {
                if (keyboard.getModifiers().alt) {
                    server.handleMousebind(event.button, self.wlr_cursor.x, self.wlr_cursor.y);
                    return;
                }
            }
            self.click_serial = seat.pointerNotifyButton(event);
            if (output.workspace.tileAt(self.wlr_cursor.x, self.wlr_cursor.y)) |toplevel| {
                server.focusView(toplevel);
            }
        },
        .released => {
            switch (self.state) {
                .passthrough => {},
                .move => |move| self.endMove(move.toplevel, event.time_msec),
                .resize => seat.pointerNotifyExit(),
            }
            self.state = .{ .passthrough = {} };
            _ = seat.pointerNotifyButton(event);
        },
        _ => _ = seat.pointerNotifyButton(event),
    }
}

fn onAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const self: *Self = @fieldParentPtr("on_axis", listener);
    const seat = self.getSeat();
    const server = seat.getServer();
    const output = server.getOutputAtCursor() orelse return;

    if (seat.wlr_seat.getKeyboard()) |keyboard| {
        if (keyboard.getModifiers().alt) {
            output.workspace.scroll += event.delta;
            output.workspace.applyLayout();
            return;
        }
    }

    self.getSeat().pointerNotifyAxis(event);
}

fn onFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const self: *Self = @fieldParentPtr("on_frame", listener);
    self.getSeat().pointerNotifyFrame();
}

fn processMotion(self: *Self, time_msec: u32) void {
    switch (self.state) {
        .passthrough => self.updatePassthrough(time_msec),
        .move => |state| self.updateMove(state),
        .resize => |state| self.updateResize(state),
    }
}

pub fn startMove(self: *Self, toplevel: *Toplevel) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    seat.pointerNotifyExit();
    self.wlr_cursor.setXcursor(server.cursor_mgr, "hand1");

    const rect = toplevel.getRect();

    const cx: f64 = rect.x - self.wlr_cursor.x;
    const cy: f64 = rect.y - self.wlr_cursor.y;

    const new_size: struct { x: f64, y: f64 } = if (rect.width > rect.height)
        .{ .x = 256, .y = 256 * (rect.height / rect.width) }
    else
        .{ .x = 256 * (rect.width / rect.height), .y = 256 };

    const x_offset = cx * new_size.x / rect.width;
    const y_offset = cy * new_size.y / rect.width;

    toplevel.managed = true;
    toplevel.setRect(
        @intFromFloat(self.wlr_cursor.x + x_offset),
        @intFromFloat(self.wlr_cursor.y + y_offset),
        @intFromFloat(new_size.x),
        @intFromFloat(new_size.y),
    );
    toplevel.scene_tree.node.raiseToTop();

    self.state = .{
        .move = .{
            .toplevel = toplevel,
            .x_offset = x_offset,
            .y_offset = y_offset,
        },
    };
}

pub fn updateMove(self: *Self, state: State.Move) void {
    state.toplevel.setPos(
        @intFromFloat(self.wlr_cursor.x + state.x_offset),
        @intFromFloat(self.wlr_cursor.y + state.y_offset),
    );
}

pub fn startResize(self: *Self, toplevel: *Toplevel, edges: wlr.Edges) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    if (edges.left or edges.right) {
        if (edges.top or edges.bottom) {
            self.wlr_cursor.setXcursor(server.cursor_mgr, "all-scroll");
        } else {
            self.wlr_cursor.setXcursor(server.cursor_mgr, "col-resize");
        }
    } else if (edges.top or edges.bottom) {
        self.wlr_cursor.setXcursor(server.cursor_mgr, "row-resize");
    } else {
        return;
    }
    seat.pointerNotifyExit();

    const rect = toplevel.getRect();

    // OH GOD D:
    const edge_x =
        if (edges.left)
            rect.x
        else if (edges.right)
            rect.x + rect.width
        else
            self.wlr_cursor.x;

    const edge_y =
        if (edges.top)
            rect.y
        else if (edges.bottom)
            rect.y + rect.height
        else
            self.wlr_cursor.y;

    server.seat.cursor.state = .{
        .resize = .{
            .toplevel = toplevel,
            .edges = edges,
            // OH NO...
            .x_offset = edge_x - self.wlr_cursor.x,
            .y_offset = edge_y - self.wlr_cursor.y,
        },
    };
}

pub fn setSurface(self: *Self, surface: ?*wlr.Surface, hotspot_x: i32, hotspot_y: i32) void {
    switch (self.state) {
        .passthrough => self.wlr_cursor.setSurface(surface, hotspot_x, hotspot_y),
        .move, .resize => {},
    }
}

fn endMove(self: *Self, toplevel: *Toplevel, time_msec: u32) void {
    const swap_with = toplevel.workspace.tileAt(self.wlr_cursor.x, self.wlr_cursor.y) orelse return;

    toplevel.managed = false;
    toplevel.workspace.swapTiles(toplevel, swap_with);
    toplevel.workspace.applyLayout();

    self.updatePassthrough(time_msec);
}

fn updatePassthrough(self: *Self, time_msec: u32) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    if (server.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |view_at| {
        seat.pointerNotifyEnter(
            view_at.surface,
            view_at.sx,
            view_at.sy,
            time_msec,
        );
    } else {
        self.wlr_cursor.setXcursor(server.cursor_mgr, "default");
        seat.pointerNotifyExit();
    }
}

fn updateResize(self: *Self, state: State.Resize) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    const workspace = state.toplevel.workspace;

    const output = server.output_layout.outputAt(self.wlr_cursor.x, self.wlr_cursor.y) orelse return;
    var layout_dirty = false;

    const x = self.wlr_cursor.x + state.x_offset;
    const y = self.wlr_cursor.y + state.y_offset;
    if ((state.toplevel.index != 0 and state.edges.left) or
        (state.toplevel.index == 0 and state.edges.right))
    {
        workspace.horizontal_ratio = x / @as(f64, @floatFromInt(output.width));
        layout_dirty = true;
    }

    if (state.toplevel.index > 1 and state.edges.top) {
        const prev = workspace.toplevels.items[state.toplevel.index - 1];
        prev.workspace.resizeTile(prev, y);
        layout_dirty = true;
    }

    if (state.toplevel.index != 0 and
        state.toplevel.index != workspace.len() - 1 and
        state.edges.bottom)
    {
        workspace.resizeTile(state.toplevel, y);
        layout_dirty = true;
    }

    if (layout_dirty == true) {
        state.toplevel.workspace.applyLayout();
    }
}
