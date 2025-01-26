const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("mach-glfw");

const HEIGHT = 600;
const WIDTH = 800;

/// Default GLFW error handling callback
fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

const HelloTriangle = struct {
    var window: glfw.Window = undefined;

    pub fn run(_: *const HelloTriangle) !void {
        initWindow() catch |err| {
            std.log.err("init window failed\n", .{});
            return err;
        };
        initVulkan();
        mainLoop();
    }
    fn initVulkan() void {}
    fn initWindow() !void {
        if (!glfw.init(.{})) {
            std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        }
        window = glfw.Window.create(WIDTH, HEIGHT, "Vulkan Tutorial!", null, null, .{ .client_api = .no_api }) orelse {
            std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        };
    }

    fn mainLoop() void {
        while (!window.shouldClose()) {
            glfw.pollEvents();
        }
    }

    fn cleanup(_: *const HelloTriangle) void {
        window.destroy();
        glfw.terminate();
    }
};

pub fn main() !void {
    var app = HelloTriangle{};
    defer app.cleanup();

    app.run() catch |err| {
        std.log.err("error in application: {s}\n", .{err});
        return err;
    };
    return;
}
