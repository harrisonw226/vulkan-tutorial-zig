const std = @import("std");
const glfw = @import("mach-glfw");

const Allocator = std.mem.Allocator;

const app_name = "vulkan zig example";

const HEIGHT = 600;
const WIDTH = 800;

/// Default GLFW error handling callback
fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

pub fn main() !void {
    if (!glfw.init(.{})) {
        std.log.err("failed to initialise GLFW: {?s}\n", .{glfw.getErrorString()});
        return glfw.getErrorCode();
    }
    defer glfw.terminate();

    const window = glfw.Window.create(WIDTH, HEIGHT, app_name, null, null, .{ .client_api = .no_api }) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return glfw.getErrorCode();
    };
    defer window.destroy();

    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}
