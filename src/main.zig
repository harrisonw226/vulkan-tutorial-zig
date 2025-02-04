const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("mach-glfw");
const GraphicsConstext = @import("graphics_context.zig").GraphicsContext;

const Allocator = std.mem.Allocator;

const app_name = "vulkan zig example";

const HEIGHT = 600;
const WIDTH = 800;
const enable_validation_layers = builtin.mode == .Debug;

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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const gc = try GraphicsConstext.init(allocator, app_name, window, enable_validation_layers);
    defer gc.deinit();

    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}
