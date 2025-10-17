const Self = @This();

const std = @import("std");
const debug = std.debug;
const log = std.log;
const posix = std.posix;
const process = std.process;
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Output = @import("Output.zig");
const Workspace = @import("Workspace.zig");

const Seat = @import("seat/Seat.zig");
const Keyboard = @import("seat/Keyboard.zig");

const XdgShell = @import("xdg_shell/XdgShell.zig");
const Popup = @import("xdg_shell/Popup.zig");
const Toplevel = @import("xdg_shell/Toplevel.zig");

wl_server: *wl.Server,
backend: *wlr.Backend,
renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
scene: *wlr.Scene,
output_layout: *wlr.OutputLayout,
scene_output_layout: *wlr.SceneOutputLayout,
cursor_mgr: *wlr.XcursorManager,

seat: Seat,
xdg_shell: XdgShell,

on_new_input: wl.Listener(*wlr.InputDevice) = .init(newInput),
on_new_output: wl.Listener(*wlr.Output) = .init(newOutput),

workspaces: [10]Workspace = @splat(.{}),
active_workspace: u8 = 0,

socket_buf: [11]u8 = undefined,
socket_name: [:0]const u8 = undefined,

pub fn init() !Self {
    const wl_server = try wl.Server.create();
    const backend = try wlr.Backend.autocreate(wl_server.getEventLoop(), null);
    const renderer = try wlr.Renderer.autocreate(backend);
    const output_layout = try wlr.OutputLayout.create(wl_server);
    const scene = try wlr.Scene.create();
    return .{
        .wl_server = wl_server,
        .backend = backend,
        .renderer = renderer,
        .allocator = try .autocreate(backend, renderer),
        .scene = scene,
        .output_layout = output_layout,
        .scene_output_layout = try scene.attachOutputLayout(output_layout),
        .xdg_shell = try .init(wl_server),
        .seat = try .init(wl_server, "default"),
        .cursor_mgr = try .create(null, 24),
    };
}

pub fn start(self: *Self) !void {
    try self.renderer.initServer(self.wl_server);

    _ = try wlr.Compositor.create(self.wl_server, 6, self.renderer);
    _ = try wlr.Subcompositor.create(self.wl_server);
    _ = try wlr.DataDeviceManager.create(self.wl_server);

    self.backend.events.new_input.add(&self.on_new_input);
    self.backend.events.new_output.add(&self.on_new_output);

    self.seat.start();
    self.xdg_shell.start();

    self.seat.cursor.wlr_cursor.attachOutputLayout(self.output_layout);
    try self.cursor_mgr.load(1);

    self.socket_name = try self.wl_server.addSocketAuto(&self.socket_buf);

    try self.backend.start();
    self.wl_server.run();
}

pub fn deinit(self: *Self) void {
    self.wl_server.destroyClients();

    self.on_new_input.link.remove();
    self.on_new_output.link.remove();

    self.seat.deinit();
    self.xdg_shell.deinit();

    self.backend.destroy();
    self.wl_server.destroy();
}

fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("on_new_output", listener);

    Output.create(self, wlr_output) catch {
        log.err("failed to allocate new output", .{});
        wlr_output.destroy();
        return;
    };
}

const ViewAtResult = struct {
    toplevel: *Toplevel,
    surface: *wlr.Surface,
    sx: f64,
    sy: f64,
};

pub fn viewAt(self: *Self, lx: f64, ly: f64) ?ViewAtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (self.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
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

pub fn focusView(self: *Self, toplevel: *Toplevel) void {
    const surface = toplevel.xdg_toplevel.base.surface;

    if (self.seat.wlr_seat.keyboard_state.focused_surface) |previous_surface| {
        if (previous_surface == surface) return;
        if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
            _ = xdg_surface.role_data.toplevel.?.setActivated(false);
        }
    }

    if (self.seat.focused_toplevel) |focused_toplevel| {
        _ = focused_toplevel.xdg_toplevel.setActivated(false);
    }

    _ = toplevel.xdg_toplevel.setActivated(true);
    self.seat.focused_toplevel = toplevel;

    const wlr_keyboard = self.seat.wlr_seat.getKeyboard() orelse return;
    self.seat.wlr_seat.keyboardNotifyEnter(
        surface,
        wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
        &wlr_keyboard.modifiers,
    );
}

fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const self: *Self = @fieldParentPtr("on_new_input", listener);
    self.seat.addInput(device);
}

pub fn getWorkspace(self: *Self, id: u8) *Workspace {
    return &self.workspaces[id];
}

pub fn getActiveWorkspace(self: *Self) *Workspace {
    return self.getWorkspace(self.active_workspace);
}

pub fn setWorkspace(self: *Self, id: u8) void {
    debug.assert(id < 10);

    self.getActiveWorkspace().hide();
    self.active_workspace = id;

    const output = self.output_layout.outputAt(0, 0) orelse unreachable;
    self.getActiveWorkspace().resize(output.width, output.height);
    self.getActiveWorkspace().applyLayout();
}

pub fn applyWorkspaceLayout(self: *Self, id: u8) void {
    if (self.active_workspace == id) {
        self.getWorkspace(id).applyLayout();
    }
}

/// Assumes the modifier used for compositor keybinds is pressed
/// Returns true if the key was handled
pub fn handleKeybind(self: *Self, key: xkb.Keysym) bool {
    switch (@intFromEnum(key)) {
        xkb.Keysym.Escape => self.wl_server.terminate(),
        xkb.Keysym.Return => {
            var child = process.Child.init(&.{"alacritty"}, gpa);

            var env_map = process.getEnvMap(gpa) catch {
                log.err("failed to get environment map!", .{});
                return false;
            };
            defer env_map.deinit();

            env_map.put("WAYLAND_DISPLAY", self.socket_name) catch {
                log.err("failed to add WAYLAND_DISPLAY to environment map!", .{});
                return false;
            };
            child.env_map = &env_map;

            child.spawn() catch {
                log.err("failed to spawn terminal window!", .{});
                return false;
            };
        },
        xkb.Keysym.@"1" => self.setWorkspace(0),
        xkb.Keysym.@"2" => self.setWorkspace(1),
        xkb.Keysym.@"3" => self.setWorkspace(2),
        xkb.Keysym.@"4" => self.setWorkspace(3),
        xkb.Keysym.@"5" => self.setWorkspace(4),
        xkb.Keysym.@"6" => self.setWorkspace(5),
        xkb.Keysym.@"7" => self.setWorkspace(6),
        xkb.Keysym.@"8" => self.setWorkspace(7),
        xkb.Keysym.@"9" => self.setWorkspace(8),
        xkb.Keysym.@"0" => self.setWorkspace(9),
        else => return false,
    }
    return true;
}
