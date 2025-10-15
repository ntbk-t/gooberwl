const Self = @This();

const std = @import("std");
const posix = std.posix;
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Keyboard = @import("Keyboard.zig");
const Output = @import("Output.zig");
const Popup = @import("Popup.zig");
const Toplevel = @import("Toplevel.zig");
const Workspace = @import("Workspace.zig");

wl_server: *wl.Server,
backend: *wlr.Backend,
renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
scene: *wlr.Scene,

output_layout: *wlr.OutputLayout,
scene_output_layout: *wlr.SceneOutputLayout,
new_output: wl.Listener(*wlr.Output) = .init(newOutput),

xdg_shell: *wlr.XdgShell,
new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevel),
new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopup),
toplevels: std.ArrayList(*Toplevel) = .empty,

seat: *wlr.Seat,
new_input: wl.Listener(*wlr.InputDevice) = .init(newInput),
request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursor),
request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelection),
keyboards: wl.list.Head(Keyboard, .link) = undefined,

cursor: *wlr.Cursor,
cursor_mgr: *wlr.XcursorManager,
cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(cursorMotion),
cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(cursorMotionAbsolute),
cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(cursorButton),
cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(cursorAxis),
cursor_frame: wl.Listener(*wlr.Cursor) = .init(cursorFrame),

focused_toplevel: ?*Toplevel = null,
horizontal_ratio: f64 = 2.0 / 3.0,
cursor_mode: enum { passthrough, resize } = .passthrough,
resize_edges: wlr.Edges = .{},
click_serial: u32 = 0,

workspace: Workspace,

socket_buf: [11]u8,
socket_name: [:0]const u8,

pub fn init(server: *Self) !void {
    const wl_server = try wl.Server.create();
    const loop = wl_server.getEventLoop();
    const backend = try wlr.Backend.autocreate(loop, null);
    const renderer = try wlr.Renderer.autocreate(backend);
    const output_layout = try wlr.OutputLayout.create(wl_server);
    const scene = try wlr.Scene.create();
    server.* = .{
        .wl_server = wl_server,
        .backend = backend,
        .renderer = renderer,
        .allocator = try wlr.Allocator.autocreate(backend, renderer),
        .scene = scene,
        .output_layout = output_layout,
        .scene_output_layout = try scene.attachOutputLayout(output_layout),
        .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
        .seat = try wlr.Seat.create(wl_server, "default"),
        .cursor = try wlr.Cursor.create(),
        .cursor_mgr = try wlr.XcursorManager.create(null, 24),
        .socket_buf = undefined,
        .socket_name = undefined,
        .workspace = .{},
    };

    try server.renderer.initServer(wl_server);

    _ = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
    _ = try wlr.Subcompositor.create(server.wl_server);
    _ = try wlr.DataDeviceManager.create(server.wl_server);

    server.backend.events.new_output.add(&server.new_output);

    server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
    server.xdg_shell.events.new_popup.add(&server.new_xdg_popup);

    server.backend.events.new_input.add(&server.new_input);
    server.seat.events.request_set_cursor.add(&server.request_set_cursor);
    server.seat.events.request_set_selection.add(&server.request_set_selection);
    server.keyboards.init();

    server.cursor.attachOutputLayout(server.output_layout);
    try server.cursor_mgr.load(1);
    server.cursor.events.motion.add(&server.cursor_motion);
    server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
    server.cursor.events.button.add(&server.cursor_button);
    server.cursor.events.axis.add(&server.cursor_axis);
    server.cursor.events.frame.add(&server.cursor_frame);

    server.socket_name = try server.wl_server.addSocketAuto(&server.socket_buf);
}

pub fn deinit(server: *Self) void {
    server.wl_server.destroyClients();

    server.new_input.link.remove();
    server.new_output.link.remove();

    server.new_xdg_toplevel.link.remove();
    server.new_xdg_popup.link.remove();
    server.request_set_cursor.link.remove();
    server.request_set_selection.link.remove();
    server.cursor_motion.link.remove();
    server.cursor_motion_absolute.link.remove();
    server.cursor_button.link.remove();
    server.cursor_axis.link.remove();
    server.cursor_frame.link.remove();

    server.backend.destroy();
    server.wl_server.destroy();
}

fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const server: *Self = @fieldParentPtr("new_output", listener);

    if (!wlr_output.initRender(server.allocator, server.renderer)) return;

    var state = wlr.Output.State.init();
    defer state.finish();

    state.setEnabled(true);
    if (wlr_output.preferredMode()) |mode| {
        state.setMode(mode);
    }
    if (!wlr_output.commitState(&state)) return;

    Output.create(server, wlr_output) catch {
        std.log.err("failed to allocate new output", .{});
        wlr_output.destroy();
        return;
    };
}

fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
    const server: *Self = @fieldParentPtr("new_xdg_toplevel", listener);
    const xdg_surface = xdg_toplevel.base;

    // Don't add the toplevel to server.toplevels until it is mapped
    const toplevel = gpa.create(Toplevel) catch {
        std.log.err("failed to allocate new toplevel", .{});
        return;
    };

    toplevel.* = .{
        .server = server,
        .xdg_toplevel = xdg_toplevel,
        .scene_tree = server.scene.tree.createSceneXdgSurface(xdg_surface) catch {
            gpa.destroy(toplevel);
            std.log.err("failed to allocate new toplevel", .{});
            return;
        },
    };
    toplevel.scene_tree.node.data = toplevel;
    xdg_surface.data = toplevel.scene_tree;

    xdg_surface.surface.events.commit.add(&toplevel.commit);
    xdg_surface.surface.events.map.add(&toplevel.map);
    xdg_surface.surface.events.unmap.add(&toplevel.unmap);
    xdg_toplevel.events.destroy.add(&toplevel.destroy);
    xdg_toplevel.events.request_move.add(&toplevel.request_move);
    xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
}

fn newXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
    const xdg_surface = xdg_popup.base;

    // These asserts are fine since tinywl.zig doesn't support anything else that can
    // make xdg popups (e.g. layer shell).
    const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
    const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
        // The xdg surface user data could be left null due to allocation failure.
        return;
    };
    const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
        std.log.err("failed to allocate xdg popup node", .{});
        return;
    };
    xdg_surface.data = scene_tree;

    const popup = gpa.create(Popup) catch {
        std.log.err("failed to allocate new popup", .{});
        return;
    };
    popup.* = .{
        .xdg_popup = xdg_popup,
    };

    xdg_surface.surface.events.commit.add(&popup.commit);
    xdg_popup.events.destroy.add(&popup.destroy);
}

const ViewAtResult = struct {
    toplevel: *Toplevel,
    surface: *wlr.Surface,
    sx: f64,
    sy: f64,
};

fn viewAt(server: *Self, lx: f64, ly: f64) ?ViewAtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

        var it: ?*wlr.SceneTree = node.parent;
        while (it) |n| : (it = n.node.parent) {
            if (@as(?*Toplevel, @ptrCast(@alignCast(n.node.data)))) |toplevel| {
                return ViewAtResult{
                    .toplevel = toplevel,
                    .surface = scene_surface.surface,
                    .sx = sx,
                    .sy = sy,
                };
            }
        }
    }
    return null;
}

pub fn focusView(server: *Self, toplevel: *Toplevel) void {
    const surface = toplevel.xdg_toplevel.base.surface;

    if (server.seat.keyboard_state.focused_surface) |previous_surface| {
        if (previous_surface == surface) return;
        if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
            _ = xdg_surface.role_data.toplevel.?.setActivated(false);
        }
    }

    if (server.focused_toplevel) |focused_toplevel| {
        _ = focused_toplevel.xdg_toplevel.setActivated(false);
    }

    _ = toplevel.xdg_toplevel.setActivated(true);
    server.focused_toplevel = toplevel;

    const wlr_keyboard = server.seat.getKeyboard() orelse return;
    server.seat.keyboardNotifyEnter(
        surface,
        wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
        &wlr_keyboard.modifiers,
    );
}

fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const server: *Self = @fieldParentPtr("new_input", listener);
    switch (device.type) {
        .keyboard => Keyboard.create(server, device) catch |err| {
            std.log.err("failed to create keyboard: {}", .{err});
            return;
        },
        .pointer => server.cursor.attachInputDevice(device),
        else => {},
    }

    server.seat.setCapabilities(.{
        .pointer = true,
        .keyboard = server.keyboards.length() > 0,
    });
}

fn requestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    const server: *Self = @fieldParentPtr("request_set_cursor", listener);
    if (event.seat_client == server.seat.pointer_state.focused_client)
        server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
}

fn requestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const server: *Self = @fieldParentPtr("request_set_selection", listener);
    server.seat.setSelection(event.source, event.serial);
}

fn cursorMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const server: *Self = @fieldParentPtr("cursor_motion", listener);
    server.cursor.move(event.device, event.delta_x, event.delta_y);
    server.processCursorMotion(event.time_msec);
}

fn cursorMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const server: *Self = @fieldParentPtr("cursor_motion_absolute", listener);
    server.cursor.warpAbsolute(event.device, event.x, event.y);
    server.processCursorMotion(event.time_msec);
}

fn processCursorMotion(server: *Self, time_msec: u32) void {
    switch (server.cursor_mode) {
        .passthrough => server.processPassthrough(time_msec),
        .resize => server.processResize(),
    }
}

fn processPassthrough(server: *Self, time_msec: u32) void {
    if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
        server.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
        server.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
    } else {
        server.cursor.setXcursor(server.cursor_mgr, "default");
        server.seat.pointerClearFocus();
    }
}

fn processResize(server: *Self) void {
    const toplevel = server.focused_toplevel orelse {
        std.log.warn("cursor mode set to resize, but no toplevel is focused!", .{});
        server.cursor_mode = .passthrough;
        return;
    };

    const output = server.output_layout.outputAt(server.cursor.x, server.cursor.y) orelse return;
    var layout_dirty = false;

    if ((toplevel.index != 0 and server.resize_edges.left) or
        (toplevel.index == 0 and server.resize_edges.right))
    {
        server.horizontal_ratio = server.cursor.x / @as(f64, @floatFromInt(output.width));
        layout_dirty = true;
    }

    if (toplevel.index != 0 and
        toplevel.index != server.toplevels.items.len - 1 and
        server.resize_edges.bottom)
    {
        const current_height = @as(f64, @floatFromInt(output.height)) * toplevel.scale / server.workspace.total_scale;

        const current_top = @as(f64, @floatFromInt(toplevel.scene_tree.node.y));
        const current_bottom = current_top + current_height;
        const ideal_bottom = server.cursor.y;

        const resize_by = (ideal_bottom - current_bottom);

        const new_height = current_height + resize_by;
        if (new_height < 1) return;

        const height_ratio = new_height / @as(f64, @floatFromInt(output.height));
        toplevel.setScale(height_ratio / (1.0 - height_ratio));

        layout_dirty = true;
    }

    if (layout_dirty) {
        server.workspace.applyLayout();
    }
}

fn cursorButton(
    listener: *wl.Listener(*wlr.Pointer.event.Button),
    event: *wlr.Pointer.event.Button,
) void {
    const server: *Self = @fieldParentPtr("cursor_button", listener);
    const serial = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    switch (event.state) {
        .pressed => {
            server.click_serial = serial;
            if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
                server.focusView(res.toplevel);
            }
        },
        .released => {
            server.cursor_mode = .passthrough;
        },
        _ => {},
    }
}

fn cursorAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const server: *Self = @fieldParentPtr("cursor_axis", listener);
    server.seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
        event.relative_direction,
    );
}

fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const server: *Self = @fieldParentPtr("cursor_frame", listener);
    server.seat.pointerNotifyFrame();
}

/// Assumes the modifier used for compositor keybinds is pressed
/// Returns true if the key was handled
pub fn handleKeybind(server: *Self, key: xkb.Keysym) bool {
    switch (@intFromEnum(key)) {
        xkb.Keysym.Escape => server.wl_server.terminate(),
        xkb.Keysym.Return => {
            var child = std.process.Child.init(&.{"alacritty"}, gpa);

            var env_map = std.process.getEnvMap(gpa) catch {
                std.log.err("failed to get environment map!", .{});
                return false;
            };
            defer env_map.deinit();

            env_map.put("WAYLAND_DISPLAY", server.socket_name) catch {
                std.log.err("failed to add WAYLAND_DISPLAY to environment map!", .{});
                return false;
            };
            child.env_map = &env_map;

            child.spawn() catch {
                std.log.err("failed to spawn terminal window!", .{});
                return false;
            };
        },
        else => return false,
    }
    return true;
}
