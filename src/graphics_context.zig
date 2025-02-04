const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("mach-glfw");
const Allocator = std.mem.Allocator;

const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

/// To construct base, instance and device wrappers for vulkan-zig, you need to pass a list of 'apis' to it.
const apis: []const vk.ApiInfo = &.{
    // You can either add invidiual functions by manually creating an 'api'
    .{
        .base_commands = .{
            .createInstance = true,
        },
        .instance_commands = .{
            .createDevice = true,
        },
    },
    // Or you can add entire feature sets or extensions
    vk.features.version_1_0,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
};

/// Next, pass the `apis` to the wrappers to create dispatch tables.
const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

// Also create some proxying wrappers, which also have the respective handles
const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);

pub const GrahicsContext = struct {
    allocator: Allocator,

    vkb: BaseDispatch,

    instance: Instance,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: glfw.Window) !GrahicsContext {
        var self: GrahicsContext = undefined;
        _ = window;
        self.allocator = allocator;
        self.vkb = try BaseDispatch.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)));

        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
            .p_engine_name = app_name,
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .api_version = vk.API_VERSION_1_3,
        };

        var instance_exts = std.ArrayList([*:0]const u8).init(self.allocator);
        defer instance_exts.deinit();

        for (instance_exts.items) |ext| {
            std.log.info("instance ext: {s}", .{ext});
        }

        try checkInstanceExtensions(self, &instance_exts);
        const instance = try self.vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(instance_exts.items.len),
            .pp_enabled_extension_names = @ptrCast(instance_exts.items),
        }, null);

        const vki = try allocator.create(InstanceDispatch);
        errdefer allocator.destroy(vki);

        vki.* = try InstanceDispatch.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.instance = Instance.init(instance, vki);
        errdefer self.instance.destroyInstance(null);

        return self;
    }

    pub fn deinit(self: GrahicsContext) void {
        self.instance.destroyInstance(null);
        self.allocator.destroy(self.instance.wrapper);
    }

    fn checkInstanceExtensions(self: GrahicsContext, instance_exts: *std.ArrayList([*:0]const u8)) !void {
        // Gets available extensions
        var count: u32 = 0;
        _ = try self.vkb.enumerateInstanceExtensionProperties(null, &count, null);
        const available_exts = try self.allocator.alloc(vk.ExtensionProperties, count);
        defer self.allocator.free(available_exts);
        _ = try self.vkb.enumerateInstanceExtensionProperties(null, &count, available_exts.ptr);
        // Gets required GLFW extensions
        const glfw_exts = glfw.getRequiredInstanceExtensions() orelse return blk: {
            const err = glfw.mustGetError();
            std.log.err("failed to get required vulkan instance extensions: error {s}", .{err.description});
            break :blk err.error_code;
        };

        try instance_exts.appendSlice(glfw_exts);

        for (instance_exts.items) |reqs| {
            for (available_exts) |ext| {
                const len = std.mem.indexOfScalar(u8, &ext.extension_name, 0).?;
                const ext_name = ext.extension_name[0..len];
                if (std.mem.eql(u8, ext_name, std.mem.span(reqs))) {
                    std.log.info("ext: {s} <---- Required", .{ext.extension_name});
                } else {
                    std.log.info("ext: {s}", .{ext.extension_name});
                }
            }
        }
    }
};
