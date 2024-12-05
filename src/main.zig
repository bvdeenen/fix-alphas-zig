const spng = @cImport(@cInclude("spng.h"));
const std = @import("std");
const c = @cImport({
    @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("stdio.h");
});

pub fn main() !u8 {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(general_purpose_allocator.deinit() == .ok);
    const gpa = general_purpose_allocator.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer _ = std.process.argsFree(gpa, args);
    if (std.os.argv.len != 3) {
        std.debug.print("Use {s} <input.png> <output.png>\n", .{args[0]});
        return 1;
    }

    const in_file = args[1];
    const out_file = args[2];

    const ctx = spng.spng_ctx_new(0) orelse unreachable;
    const file = c.fopen(in_file.ptr, "rb");
    if (file == null) {
        std.debug.print("Can't open file {s}\n", .{in_file});
        return 3;
    }
    defer _ = c.fclose(file);
    const limit = 1024 * 1024 * 64;
    var ret = spng.spng_set_chunk_limits(ctx, limit, limit);
    if (ret != 0) {
        std.debug.print("spng_set_chunk_limits error {}\n", .{ret});
        return 1;
    }
    ret = spng.spng_set_png_file(ctx, @ptrCast(file));
    if (ret != 0) {
        std.debug.print("spng_set_png_file error {}\n", .{ret});
        return 2;
    }
    var ihdr = try get_image_header(ctx);
    if (ihdr.bit_depth != 8) {
        std.debug.print("Only processing RGBA8, and not {}\n", .{ihdr.color_type});
        return 0;
    }
    const output_size = try calc_output_size(ctx);
    const buffer: []u8 = try gpa.alloc(u8, output_size);
    defer _ = gpa.free(buffer);
    @memset(buffer, 0);
    try read_data_to_buffer(ctx, buffer);
    std.debug.print("Read {d} bytes from {s}\n", .{ output_size, in_file });
    try apply_image_filter(buffer);
    try save_png(&ihdr, buffer, out_file);
    return 0;
}

fn apply_image_filter(buffer: []u8) !void {
    std.debug.print("Tresholding alpha.\n");
    var index: u64 = 0;
    while (index < buffer.len) : (index += 4) {
        const alpha = buffer[index + 3];
        // rgbA
        buffer[index + 3] = if (alpha < 0x80) 0 else 0xff;
    }
}

fn save_png(image_header: *spng.spng_ihdr, buffer: []u8, path: []u8) !void {
    const file_descriptor = c.fopen(path.ptr, "wb");
    if (file_descriptor == null) {
        return error.CouldNotOpenFile;
    }
    std.debug.print("Writing to {s}", .{path});
    const ctx = (spng.spng_ctx_new(spng.SPNG_CTX_ENCODER) orelse unreachable);
    defer spng.spng_ctx_free(ctx);
    _ = spng.spng_set_png_file(ctx, @ptrCast(file_descriptor));
    _ = spng.spng_set_ihdr(ctx, image_header);

    const encode_status = spng.spng_encode_image(ctx, buffer.ptr, buffer.len, spng.SPNG_FMT_PNG, spng.SPNG_ENCODE_FINALIZE);
    if (encode_status != 0) {
        return error.CouldNotEncodeImage;
    }
    if (c.fclose(@ptrCast(file_descriptor)) != 0) {
        return error.CouldNotCloseFileDescriptor;
    }
    std.debug.print(" ... done\n", .{});
}

fn read_data_to_buffer(ctx: *spng.spng_ctx, buffer: []u8) !void {
    const status = spng.spng_decode_image(ctx, buffer.ptr, buffer.len, spng.SPNG_FMT_RGBA8, 0);

    if (status != 0) {
        return error.CouldNotDecodeImage;
    }
}

fn get_image_header(ctx: *spng.spng_ctx) !spng.spng_ihdr {
    var image_header: spng.spng_ihdr = undefined;
    if (spng.spng_get_ihdr(ctx, &image_header) != 0) {
        return error.CouldNotGetImageHeader;
    }
    return image_header;
}

fn calc_output_size(ctx: *spng.spng_ctx) !u64 {
    var output_size: u64 = 0;
    const status = spng.spng_decoded_image_size(ctx, spng.SPNG_FMT_RGBA8, &output_size);
    if (status != 0) {
        return error.CouldNotCalcOutputSize;
    }
    return output_size;
}
