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
    vk.extensions.ext_debug_utils,
};

/// Next, pass the `apis` to the wrappers to create dispatch tables.
const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

// Also create some proxying wrappers, which also have the respective handles
const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);

pub const GraphicsContext = struct {
    allocator: Allocator,

    vkb: BaseDispatch,

    instance: Instance,

    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    dev: Device,
    graphics_queue: Queue,
    present_queue: Queue,

    enable_validation: bool,
    debug_messenger: vk.DebugUtilsMessengerEXT,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: glfw.Window, enable_validation_layers: bool) !GraphicsContext {
        var self: GraphicsContext = undefined;
        self.enable_validation = enable_validation_layers;
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

        var instance_layers = std.ArrayList([*:0]const u8).init(self.allocator);
        defer instance_layers.deinit();

        try checkInstanceExtensions(self, &instance_exts);
        try checkInstanceLayers(self, &instance_layers);

        const instance = try self.vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(instance_exts.items.len),
            .pp_enabled_extension_names = @ptrCast(instance_exts.items),
            .enabled_layer_count = @intCast(instance_layers.items.len),
            .pp_enabled_layer_names = @ptrCast(instance_layers.items),
        }, null);

        const vki = try allocator.create(InstanceDispatch);
        errdefer allocator.destroy(vki);

        vki.* = try InstanceDispatch.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.instance = Instance.init(instance, vki);
        errdefer self.instance.destroyInstance(null);

        if (enable_validation_layers) {
            self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{
                    .error_bit_ext = true,
                    .warning_bit_ext = true,
                },
                .message_type = .{
                    .general_bit_ext = true,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                    .device_address_binding_bit_ext = true,
                },
                .pfn_user_callback = debugCallback,
            }, null);
        }

        self.surface = try createSurface(self.instance, window);
        errdefer self.instance.destroySurfaceKHR(self.surface, null);

        const candidate = try pickPhysicalDevice(self.instance, allocator, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;

        const dev = try initialiseCandidate(self.instance, candidate);

        const vkd = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(vkd);

        vkd.* = try DeviceDispatch.load(dev, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
        self.dev = Device.init(dev, vkd);

        errdefer self.dev.destroyDevice(null);

        self.graphics_queue = Queue.init(self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.dev, candidate.queues.present_family);

        self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

        return self;
    }

    pub fn deinit(self: GraphicsContext) void {
        self.dev.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        self.instance.destroyInstance(null);

        self.allocator.destroy(self.dev.wrapper);
        self.allocator.destroy(self.instance.wrapper);
    }

    fn checkInstanceLayers(self: GraphicsContext, instance_layers: *std.ArrayList([*:0]const u8)) !void {
        var count: u32 = 0;
        _ = try self.vkb.enumerateInstanceLayerProperties(&count, null);
        const available_layers = try self.allocator.alloc(vk.LayerProperties, count);
        defer self.allocator.free(available_layers);
        _ = try self.vkb.enumerateInstanceLayerProperties(&count, available_layers.ptr);

        if (self.enable_validation) {
            try instance_layers.append("VK_LAYER_KHRONOS_validation");
        }

        for (instance_layers.items) |reqs| {
            for (available_layers) |ext| {
                const len = std.mem.indexOfScalar(u8, &ext.layer_name, 0).?;
                const layer_name = ext.layer_name[0..len];
                if (std.mem.eql(u8, layer_name, std.mem.span(reqs))) {
                    std.log.info("layer: {s} <---- Required", .{layer_name});
                } else {
                    std.log.info("layer: {s}", .{layer_name});
                }
            }
        }
    }

    fn checkInstanceExtensions(self: GraphicsContext, instance_exts: *std.ArrayList([*:0]const u8)) !void {
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
        if (self.enable_validation) {
            try instance_exts.append("VK_EXT_debug_utils");
        }

        for (instance_exts.items) |reqs| {
            for (available_exts) |ext| {
                const len = std.mem.indexOfScalar(u8, &ext.extension_name, 0).?;
                const ext_name = ext.extension_name[0..len];
                if (std.mem.eql(u8, ext_name, std.mem.span(reqs))) {
                    std.log.info("ext: {s} <---- Required", .{ext_name});
                } else {
                    std.log.info("ext: {s}", .{ext_name});
                }
            }
        }
    }
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

fn initialiseCandidate(instance: Instance, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1
    else
        2;

    return try instance.createDevice(candidate.pdev, &.{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
    }, null);
}

fn pickPhysicalDevice(instance: Instance, allocator: Allocator, surface: vk.SurfaceKHR) !DeviceCandidate {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }
    return error.NoSuitbaleDevices;
}

fn checkSuitable(instance: Instance, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, pdev, allocator)) {
        std.log.err("missing extensions", .{});
        return null;
    }

    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        std.log.err("missing surface support", .{});
        return null;
    }

    if (try allocateQueues(instance, pdev, allocator, surface)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(pdev);
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }
    std.log.err("failed to allocate queues", .{});
    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properites, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properites.queue_flags.graphics_bit) {
            graphics_family = family;
        }
        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }

        if (graphics_family != null and present_family != null) {
            return QueueAllocation{
                .graphics_family = graphics_family.?,
                .present_family = present_family.?,
            };
        }
    }
    return null;
}

fn createSurface(instance: Instance, window: glfw.Window) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (glfw.createWindowSurface(instance.handle, window, null, &surface) != @intFromEnum(vk.Result.success)) {
        return error.SurfaceInitFailed;
    }
    return surface;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(instance: Instance, pdev: vk.PhysicalDevice, allocator: Allocator) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_severity;
    _ = message_types;
    _ = p_user_data;
    b: {
        const msg = (p_callback_data orelse break :b).p_message orelse break :b;
        std.log.scoped(.validation).warn("{s}", .{msg});
        return vk.FALSE;
    }
    std.log.scoped(.validation).warn("unrecognized validation layer debug message", .{});
    return vk.FALSE;
}
