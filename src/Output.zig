const Self = @This();

const std = @import("std");
const posix = std.posix;
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("Server.zig");
const Workspace = @import("Workspace.zig");

server: *Server,
workspace: *Workspace,
wlr_output: *wlr.Output,

frame: wl.Listener(*wlr.Output) = .init(handleFrame),
request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(handleRequestState),
destroy: wl.Listener(*wlr.Output) = .init(handleDestroy),

// The wlr.Output should be destroyed by the caller on failure to trigger cleanup.
pub fn create(server: *Server, wlr_output: *wlr.Output) !void {
    if (!wlr_output.initRender(server.allocator, server.renderer)) return;

    var state = wlr.Output.State.init();
    defer state.finish();

    state.setEnabled(true);
    if (wlr_output.preferredMode()) |mode| {
        state.setMode(mode);
    }
    if (!wlr_output.commitState(&state)) return;

    const workspace = for (&server.workspaces) |*workspace| {
        if (workspace.output == null) {
            break workspace;
        }
    } else {
        std.log.err("no workspaces left to provide to output \"{s}\"!", .{wlr_output.name});
        return error.NoWorkspaces;
    };

    const output = try gpa.create(Self);
    errdefer gpa.destroy(output);
    output.* = .{
        .server = server,
        .workspace = workspace,
        .wlr_output = wlr_output,
    };

    wlr_output.data = @ptrCast(output);
    workspace.output = output;

    const layout_output = try server.output_layout.addAuto(wlr_output);

    const scene_output = try server.scene.createSceneOutput(wlr_output);
    server.scene_output_layout.addOutput(layout_output, scene_output);

    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.destroy.add(&output.destroy);
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Self = @fieldParentPtr("frame", listener);

    const scene_output = output.server.scene.getSceneOutput(output.wlr_output).?;
    _ = scene_output.commit(null);

    var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
}

fn handleRequestState(
    listener: *wl.Listener(*wlr.Output.event.RequestState),
    event: *wlr.Output.event.RequestState,
) void {
    const self: *Self = @fieldParentPtr("request_state", listener);

    _ = self.wlr_output.commitState(event.state);
    self.workspace.applyLayout();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("destroy", listener);

    self.frame.link.remove();
    self.request_state.link.remove();
    self.destroy.link.remove();

    gpa.destroy(self);
}
