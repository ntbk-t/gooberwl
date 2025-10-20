const std = @import("std");
const posix = std.posix;
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Output = @import("Output.zig");
const Server = @import("Server.zig");

server: *Server,
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

    const output = try gpa.create(Output);
    errdefer gpa.destroy(output);
    output.* = .{
        .server = server,
        .wlr_output = wlr_output,
    };

    const layout_output = try server.output_layout.addAuto(wlr_output);

    const scene_output = try server.scene.createSceneOutput(wlr_output);
    server.scene_output_layout.addOutput(layout_output, scene_output);

    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.destroy.add(&output.destroy);

    const workspace = server.activeWorkspace();
    workspace.resize(output.wlr_output.width, output.wlr_output.height);
    workspace.applyLayout();
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame", listener);

    const scene_output = output.server.scene.getSceneOutput(output.wlr_output).?;
    _ = scene_output.commit(null);

    var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
}

fn handleRequestState(
    listener: *wl.Listener(*wlr.Output.event.RequestState),
    event: *wlr.Output.event.RequestState,
) void {
    const output: *Output = @fieldParentPtr("request_state", listener);

    _ = output.wlr_output.commitState(event.state);

    const workspace = output.server.activeWorkspace();
    workspace.resize(output.wlr_output.width, output.wlr_output.height);
    workspace.applyLayout();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy", listener);

    output.frame.link.remove();
    output.request_state.link.remove();
    output.destroy.link.remove();

    gpa.destroy(output);
}
