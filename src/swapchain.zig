const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Allocator = std.mem.Allocator;

pub const Swapchain = struct {
    pub const PresentState = enum {
        optimal,
        suboptimal,
    };

    gc: *const GraphicsContext,
    allocator: Allocator,

    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,

    swap_images: []SwapImage,
    image_index: u32,
    next_image_acquired: vk.Semaphore,

    pub fn init(gc: *const GraphicsContext, allocator: Allocator, extent: vk.Extent2D) !Swapchain {
        return try initRecycle(gc, allocator, extent, .null_handle);
    }

    pub fn initRecycle(gc: *const GraphicsContext, allocator: Allocator, extent: vk.Extent2D, old_handle: vk.SwapchainKHR) !Swapchain {
        const capabilities = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
        const actual_extent = findActualExtent(capabilities, extent);

        if (actual_extent.width == 0 or actual_extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }

        const surface_format = try findSurfaceFormat(gc, allocator);
        const present_mode = try findPresentMode(gc, allocator);

        var image_count = capabilities.min_image_count + 1;
        if (capabilities.max_image_count > 0) {
            image_count = @min(image_count, capabilities.max_image_count);
        }

        const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family };
        const sharing_mode: vk.SharingMode = if (gc.graphics_queue.family != gc.present_queue.family)
            .concurrent
        else
            .exclusive;

        const handle = try gc.dev.createSwapchainKHR(&.{
            .surface = gc.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = actual_extent,
            .image_array_layers = 1,
            .image_usage = .{
                .color_attachment_bit = true,
                .transfer_dst_bit = true,
            },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = qfi.len,
            .p_queue_family_indices = &qfi,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{
                .opaque_bit_khr = true,
            },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_handle,
        }, null);
        errdefer gc.dev.destroySwapchainKHR(handle, null);

        if (old_handle != .null_handle) {
            gc.dev.destroySwapchainKHR(old_handle, null);
        }

        const swap_images = try initSwapchainImages(gc, handle, surface_format.format, allocator);
        errdefer {
            for (swap_images) |si| si.deinit(gc);
            allocator.free(swap_images);
        }

        var next_image_acquired = try gc.dev.createSemaphore(&.{}, null);
        errdefer gc.dev.destroySemaphore(next_image_acquired, null);

        const result = try gc.dev.acquireNextImageKHR(handle, std.math.maxInt(u64), next_image_acquired, .null_handle);
        if (result.result != .success and result.result != vk.Result.suboptimal_khr) {
            return error.ImageAcquireFailed;
        }

        std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);

        return Swapchain{
            .gc = gc,
            .allocator = allocator,
            .surface_format = surface_format,
            .present_mode = present_mode,
            .extent = actual_extent,
            .handle = handle,
            .swap_images = swap_images,
            .image_index = result.image_index,
            .next_image_acquired = next_image_acquired,
        };
    }

    fn deinitExceptSwapchain(self: Swapchain) void {
        for (self.swap_images) |si| si.deinit(self.gc);
        self.allocator.free(self.swap_images);
        self.gc.dev.destroySemaphore(self.next_image_acquired, null);
    }

    pub fn deinit(self: Swapchain) void {
        self.deinitExceptSwapchain();
        self.gc.dev.destroySwapchainKHR(self.handle, null);
    }

    pub fn waitForAllFences(self: Swapchain) !void {
        for (self.swap_images) |si| si.waitForFence(self.gc) catch {};
    }

    pub fn recreate(self: *Swapchain, new_extent: vk.Extent2D) !void {
        const gc = self.gc;
        const allocator = self.allocator;
        const old_handle = self.handle;
        self.deinitExceptSwapchain();
        self.* = try initRecycle(gc, allocator, new_extent, old_handle);
    }

    pub fn currentImage(self: Swapchain) vk.Image {
        return self.swap_images[self.image_index].image;
    }

    pub fn currentSwapImage(self: Swapchain) *const SwapImage {
        return &self.swap_images[self.image_index];
    }

    pub fn present(self: *Swapchain, frame: u64) !PresentState {
        // 1) Wait for and reset fence of current image
        // 2) Submit command buffer, signalling fence of current image and dependent on
        //    the semaphore signalled by step 4.
        // 3) Present current frame, dependent on semaphore signalled by the submit
        // 4) Acquire next image, signalling its semaphore
        // One problem that arises is that we can't know beforehand which semaphore to signal,
        // so we keep an extra auxilery semaphore that is swapped around

        // Step 1: Make sure the current frame has finished rendering
        const current = self.currentSwapImage();
        try current.waitForFence(self.gc);
        try self.gc.dev.resetFences(1, @ptrCast(&current.frame_fence));

        try self.gc.dev.resetCommandBuffer(current.command_buffer.*, .{});

        try self.gc.dev.beginCommandBuffer(current.command_buffer.*, &.{
            .flags = .{
                .one_time_submit_bit = true,
            },
        });

        transitionImage(self.gc, current.command_buffer.*, current.image, vk.ImageLayout.undefined, vk.ImageLayout.general);

        const colour: f32 = @abs(@sin(@as(f32, @floatFromInt(frame / 120))));

        const clear_value = vk.ClearColorValue{
            .float_32 = .{ 0, 0, colour, 1 },
        };

        const clear_range = vk.ImageSubresourceRange{
            .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        };

        self.gc.dev.cmdClearColorImage(current.command_buffer.*, current.image, vk.ImageLayout.general, &clear_value, 1, @ptrCast(&clear_range));

        transitionImage(self.gc, current.command_buffer.*, current.image, vk.ImageLayout.general, vk.ImageLayout.present_src_khr);

        try self.gc.dev.endCommandBuffer(current.command_buffer.*);

        const cmd_info = commandBufferSubmitInfo(current.command_buffer.*);
        const wait_info = semaphoreSubmitInfo(current.image_acquired, vk.PipelineStageFlags2{ .color_attachment_output_bit = true });
        const sig_info = semaphoreSubmitInfo(current.render_finished, vk.PipelineStageFlags2{ .all_graphics_bit = true });

        const submit_info = submitInfo(&cmd_info, &sig_info, &wait_info);

        try self.gc.dev.queueSubmit2(self.gc.graphics_queue.handle, 1, @ptrCast(&submit_info), current.frame_fence);

        _ = try self.gc.dev.queuePresentKHR(self.gc.present_queue.handle, &.{
            .p_swapchains = @ptrCast(&self.handle),
            .swapchain_count = 1,
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.render_finished),
            .p_image_indices = @ptrCast(&self.image_index),
        });

        // Step 4: Acquire next frame
        const result = try self.gc.dev.acquireNextImageKHR(
            self.handle,
            std.math.maxInt(u64),
            self.next_image_acquired,
            .null_handle,
        );
        std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
        self.image_index = result.image_index;
        // std.log.info("frame: {d}", .{self.image_index});

        return switch (result.result) {
            .success => .optimal,
            .suboptimal_khr => .suboptimal,
            else => unreachable,
        };
    }
};

const SwapImage = struct {
    allocator: Allocator,
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,
    command_pool: vk.CommandPool,
    command_buffer: *vk.CommandBuffer,

    fn init(gc: *const GraphicsContext, image: vk.Image, format: vk.Format, allocator: Allocator) !SwapImage {
        const view = try gc.dev.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        errdefer gc.dev.destroyImageView(view, null);

        const image_acquired = try gc.dev.createSemaphore(&.{}, null);
        errdefer gc.dev.destroySemaphore(image_acquired, null);

        const render_finished = try gc.dev.createSemaphore(&.{}, null);
        errdefer gc.dev.destroySemaphore(render_finished, null);

        const frame_fence = try gc.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer gc.dev.destroyFence(frame_fence, null);

        const command_pool = try gc.dev.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = gc.graphics_queue.family,
        }, null);
        errdefer gc.dev.destroyCommandPool(command_pool, null);

        const cmdbuf = try allocator.create(vk.CommandBuffer);
        errdefer allocator.destroy(cmdbuf);

        try gc.dev.allocateCommandBuffers(&.{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(cmdbuf));
        errdefer gc.dev.freeCommandBuffers(command_pool, 1, @ptrCast(cmdbuf));

        return SwapImage{
            .allocator = allocator,
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
            .command_pool = command_pool,
            .command_buffer = cmdbuf,
        };
    }

    fn deinit(self: SwapImage, gc: *const GraphicsContext) void {
        self.waitForFence(gc) catch return;
        gc.dev.destroyImageView(self.view, null);
        gc.dev.destroySemaphore(self.image_acquired, null);
        gc.dev.destroySemaphore(self.render_finished, null);
        gc.dev.destroyFence(self.frame_fence, null);
        gc.dev.freeCommandBuffers(self.command_pool, 1, @ptrCast(self.command_buffer));
        self.allocator.destroy(self.command_buffer);
        gc.dev.destroyCommandPool(self.command_pool, null);
    }

    fn waitForFence(self: SwapImage, gc: *const GraphicsContext) !void {
        _ = try gc.dev.waitForFences(1, @ptrCast(&self.frame_fence), vk.TRUE, std.math.maxInt(u64));
    }
};

fn initSwapchainImages(gc: *const GraphicsContext, swapchain: vk.SwapchainKHR, format: vk.Format, allocator: Allocator) ![]SwapImage {
    const images = try gc.dev.getSwapchainImagesAllocKHR(swapchain, allocator);
    defer allocator.free(images);

    const swap_images = try allocator.alloc(SwapImage, images.len);
    errdefer allocator.free(swap_images);

    var i: usize = 0;

    errdefer for (swap_images[0..i]) |si| si.deinit(gc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(gc, image, format, allocator);
        i += 1;
    }
    return swap_images;
}

fn findPresentMode(gc: *const GraphicsContext, allocator: Allocator) !vk.PresentModeKHR {
    const prefered = [_]vk.PresentModeKHR{ .mailbox_khr, .immediate_khr };

    const present_modes = try gc.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(gc.pdev, gc.surface, allocator);
    defer allocator.free(present_modes);

    for (prefered) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }
    return .fifo_khr;
}

fn findSurfaceFormat(gc: *const GraphicsContext, allocator: Allocator) !vk.SurfaceFormatKHR {
    const prefered = vk.SurfaceFormatKHR{
        .format = .b8g8r8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    const surface_formats = try gc.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(gc.pdev, gc.surface, allocator);
    defer allocator.free(surface_formats);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, prefered)) {
            return prefered;
        }
    }
    return surface_formats[0];
}

fn findActualExtent(capabilities: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (capabilities.current_extent.width != 0xFFFF_FFFF) {
        return capabilities.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
            .height = std.math.clamp(extent.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
        };
    }
}

fn transitionImage(gc: *const GraphicsContext, cmd: vk.CommandBuffer, image: vk.Image, current_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    const aspect_mask: vk.ImageAspectFlags = if (new_layout == vk.ImageLayout.depth_attachment_optimal)
        vk.ImageAspectFlags{ .depth_bit = true }
    else
        vk.ImageAspectFlags{ .color_bit = true };

    const subresource_range = vk.ImageSubresourceRange{
        .aspect_mask = aspect_mask,
        .base_mip_level = 0,
        .level_count = vk.REMAINING_MIP_LEVELS,
        .base_array_layer = 0,
        .layer_count = vk.REMAINING_ARRAY_LAYERS,
    };

    const image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{
            .all_commands_bit = true,
        },
        .src_access_mask = .{
            .memory_write_bit = true,
        },
        .dst_stage_mask = .{
            .all_commands_bit = true,
        },
        .dst_access_mask = .{
            .memory_write_bit = true,
            .memory_read_bit = true,
        },

        .old_layout = current_layout,
        .new_layout = new_layout,

        .subresource_range = subresource_range,
        .image = image,
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    gc.dev.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&image_barrier),
    });
}

fn semaphoreSubmitInfo(semaphore: vk.Semaphore, stage_mask: vk.PipelineStageFlags2) vk.SemaphoreSubmitInfo {
    return vk.SemaphoreSubmitInfo{
        .semaphore = semaphore,
        .stage_mask = stage_mask,
        .device_index = 0,
        .value = 1,
    };
}

fn commandBufferSubmitInfo(cmdbuf: vk.CommandBuffer) vk.CommandBufferSubmitInfo {
    return vk.CommandBufferSubmitInfo{
        .command_buffer = cmdbuf,
        .device_mask = 0,
    };
}

fn submitInfo(cmdbuf_info: *const vk.CommandBufferSubmitInfo, signal_semaphore_info: ?*const vk.SemaphoreSubmitInfo, wait_semaphore_info: ?*const vk.SemaphoreSubmitInfo) vk.SubmitInfo2 {
    const wait_count: u32 = if (wait_semaphore_info == null) 0 else 1;
    const signal_count: u32 = if (signal_semaphore_info == null) 0 else 1;

    return vk.SubmitInfo2{
        .wait_semaphore_info_count = wait_count,
        .p_wait_semaphore_infos = @ptrCast(wait_semaphore_info),

        .signal_semaphore_info_count = signal_count,
        .p_signal_semaphore_infos = @ptrCast(signal_semaphore_info),

        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(cmdbuf_info),
    };
}
