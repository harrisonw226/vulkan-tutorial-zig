const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const glfw = @import("mach-glfw");
const Swapchain = @import("swapchain.zig").Swapchain;
const GraphicsConstext = @import("graphics_context.zig").GraphicsContext;

const Allocator = std.mem.Allocator;

const app_name = "vulkan zig example";

var extent = vk.Extent2D{ .width = 800, .height = 600 };
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

    const window = glfw.Window.create(extent.width, extent.height, app_name, null, null, .{ .client_api = .no_api }) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return glfw.getErrorCode();
    };
    defer window.destroy();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const gc = try GraphicsConstext.init(allocator, app_name, window, enable_validation_layers);
    defer gc.deinit();

    var swapchain = try Swapchain.init(&gc, allocator, extent);
    defer swapchain.deinit();

    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}
