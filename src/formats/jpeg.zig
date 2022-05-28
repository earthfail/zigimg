const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("../errors.zig");
const image = @import("../image.zig");
const FormatInterface = @import("../format_interface.zig").FormatInterface;
const color = @import("../color.zig");
const PixelFormat = @import("../pixel_format.zig").PixelFormat;
const ImageReader = image.ImageReader;
const ImageSeekStream = image.ImageSeekStream;
const ImageFormat = image.ImageFormat;
const ImageInfo = image.ImageInfo;

// TODO: Chroma subsampling
// TODO: Progressive scans
// TODO: Non-baseline sequential DCT
// TODO: Precisions other than 8-bit

const JPEG_DEBUG = false;
const JPEG_VERY_DEBUG = false;

// Marker codes

const Markers = enum(u16) {
    // Start of Frame markers, non-differential, Huffman coding
    SOF0 = 0xFFC0, // Baseline DCT
    SOF1 = 0xFFC1, // Extended sequential DCT
    SOF2 = 0xFFC2, // Progressive DCT
    SOF3 = 0xFFC3, // Lossless sequential
    // Start of Frame markers, differential, Huffman coding
    SOF5 = 0xFFC5, // Differential sequential DCT
    SOF6 = 0xFFC6, // Differential progressive DCT
    SOF7 = 0xFFC7, // Differential lossless sequential
    // Start of Frame markers, non-differential, arithmetic coding
    SOF9 = 0xFFC9, // Extended sequential DCT
    SOF10 = 0xFFCA, // Progressive DCT
    SOF11 = 0xFFCB, // Lossless sequential
    // Start of Frame markers, differential, arithmetic coding
    SOF13 = 0xFFCD, // Differential sequential DCT
    SOF14 = 0xFFCE, // Differential progressive DCT
    SOF15 = 0xFFCF, // Differential lossless sequential

    DefineHuffmanTables = 0xFFC4,
    DefineArithmeticCoding = 0xFFCC,

    StartOfImage = 0xFFD8,
    EndOfImage = 0xFFD9,
    StartOfScan = 0xFFDA,
    DefineQuantizationTables = 0xFFDB,
    DefineNumberOfLines = 0xFFDC,
    DefineRestartInterval = 0xFFDD,
    DefineHierarchicalProgression = 0xFFDE,
    ExpandReferenceComponents = 0xFFDF,

    // Add 0-15 as needed.
    Application0 = 0xFFE0,
    // Add 0-13 as needed.
    JpegExtension0 = 0xFFF0,
    Comment = 0xFFFE,
};

const DensityUnit = enum {
    Pixels,
    DotsPerInch,
    DotsPerCm,
};

const JFIFHeader = struct {
    jfif_revision: u16,
    density_unit: DensityUnit,
    x_density: u16,
    y_density: u16,

    fn read(reader: ImageReader, seek_stream: ImageSeekStream) !JFIFHeader {
        // Read the first APP0 header.
        try seek_stream.seekTo(2);
        const maybe_app0_marker = try reader.readIntBig(u16);
        if (maybe_app0_marker != @enumToInt(Markers.Application0)) {
            return error.App0MarkerDoesNotExist;
        }

        // Header length
        _ = try reader.readIntBig(u16);

        var identifier_buffer: [4]u8 = undefined;
        _ = try reader.read(identifier_buffer[0..]);

        if (!std.mem.eql(u8, identifier_buffer[0..], "JFIF")) {
            return error.JfifIdentifierNotSet;
        }

        // NUL byte after JFIF
        _ = try reader.readByte();

        const jfif_revision = try reader.readIntBig(u16);
        const density_unit = @intToEnum(DensityUnit, try reader.readByte());
        const x_density = try reader.readIntBig(u16);
        const y_density = try reader.readIntBig(u16);

        const thumbnailWidth = try reader.readByte();
        const thumbnailHeight = try reader.readByte();

        if (thumbnailWidth != 0 or thumbnailHeight != 0) {
            return error.ThumbnailImagesUnsupported;
        }

        // Make sure there are no application markers after us.
        if (((try reader.readIntBig(u16)) & 0xFFF0) == @enumToInt(Markers.Application0)) {
            return error.ExtraneousApplicationMarker;
        }

        try seek_stream.seekBy(-2);

        return JFIFHeader{
            .jfif_revision = jfif_revision,
            .density_unit = density_unit,
            .x_density = x_density,
            .y_density = y_density,
        };
    }
};

const QuantizationTable = union(enum) {
    Q8: [64]u8,
    Q16: [64]u16,

    pub fn read(precision: u8, reader: ImageReader) !QuantizationTable {
        // 0 = 8 bits, 1 = 16 bits
        switch (precision) {
            0 => {
                var table = QuantizationTable{ .Q8 = undefined };

                var offset: usize = 0;
                while (offset < 64) : (offset += 1) {
                    const value = try reader.readByte();
                    table.Q8[ZigzagOffsets[offset]] = value;
                }

                if (JPEG_DEBUG) {
                    var i: usize = 0;
                    while (i < 8) : (i += 1) {
                        var j: usize = 0;
                        while (j < 8) : (j += 1) {
                            std.debug.print("{d:4} ", .{table.Q8[i * 8 + j]});
                        }
                        std.debug.print("\n", .{});
                    }
                }

                return table;
            },
            1 => {
                var table = QuantizationTable{ .Q16 = undefined };

                var offset: usize = 0;
                while (offset < 64) : (offset += 1) {
                    const value = try reader.readIntBig(u16);
                    table.Q16[ZigzagOffsets[offset]] = value;
                }

                return table;
            },
            else => return error.UnknownQuantizationTablePrecision,
        }
    }
};

const HuffmanCode = struct { length_minus_one: u4, code: u16 };
const HuffmanCodeMap = std.AutoArrayHashMap(HuffmanCode, u8);

const HuffmanTable = struct {
    allocator: Allocator,

    code_counts: [16]u8,
    code_map: HuffmanCodeMap,

    table_class: u8,

    pub fn read(allocator: Allocator, table_class: u8, reader: ImageReader) !HuffmanTable {
        if (table_class & 1 != table_class)
            return error.InvalidHuffmanTableClass;

        var code_counts: [16]u8 = undefined;
        if ((try reader.read(code_counts[0..])) < 16) {
            return error.IncompleteHuffmanTable;
        }

        if (JPEG_DEBUG) std.debug.print("  Code counts: {any}\n", .{code_counts});

        var total_huffman_codes: usize = 0;
        for (code_counts) |count| total_huffman_codes += count;

        var huffman_code_map = HuffmanCodeMap.init(allocator);
        errdefer huffman_code_map.deinit();

        if (JPEG_VERY_DEBUG) std.debug.print("  Decoded huffman codes map:\n", .{});

        var code: u16 = 0;
        for (code_counts) |count, i| {
            if (JPEG_VERY_DEBUG) {
                std.debug.print("    Length {}: ", .{i + 1});
                if (count == 0) {
                    std.debug.print("(none)\n", .{});
                } else {
                    std.debug.print("\n", .{});
                }
            }

            var j: usize = 0;
            while (j < count) : (j += 1) {
                // Check if we hit all 1s, i.e. 111111 for i == 6, which is an invalid value
                if (code == (@intCast(u17, 1) << (@intCast(u5, i) + 1)) - 1) {
                    return error.InvalidHuffmanTable;
                }

                const byte = try reader.readByte();
                try huffman_code_map.put(.{ .length_minus_one = @intCast(u4, i), .code = code }, byte);
                code += 1;

                if (JPEG_VERY_DEBUG) std.debug.print("      {b} => 0x{X}\n", .{ code, byte });
            }

            code <<= 1;
        }

        return HuffmanTable{
            .allocator = allocator,
            .code_counts = code_counts,
            .code_map = huffman_code_map,
            .table_class = table_class,
        };
    }

    pub fn deinit(self: *HuffmanTable) void {
        self.code_map.deinit();
    }
};

const HuffmanReader = struct {
    table: ?*const HuffmanTable = null,
    reader: ImageReader,
    byte_buffer: u8 = 0,
    bits_left: u4 = 0,
    last_byte_was_ff: bool = false,

    pub fn init(reader: ImageReader) HuffmanReader {
        return .{
            .reader = reader,
        };
    }

    pub fn setHuffmanTable(self: *HuffmanReader, table: *const HuffmanTable) void {
        self.table = table;
    }

    fn readBit(self: *HuffmanReader) !u1 {
        if (self.bits_left == 0) {
            self.byte_buffer = try self.reader.readByte();

            if (self.byte_buffer == 0 and self.last_byte_was_ff) {
                // This was a stuffed byte, read one more.
                self.byte_buffer = try self.reader.readByte();
            }
            self.last_byte_was_ff = self.byte_buffer == 0xFF;
            self.bits_left = 8;
        }

        const bit: u1 = @intCast(u1, self.byte_buffer >> 7);
        self.byte_buffer <<= 1;
        self.bits_left -= 1;

        return bit;
    }

    pub fn readCode(self: *HuffmanReader) !u8 {
        var code: u16 = 0;

        var i: u5 = 0;
        while (i < 16) : (i += 1) {
            code = (code << 1) | (try self.readBit());
            if (self.table.?.code_map.get(.{ .length_minus_one = @intCast(u4, i), .code = code })) |value| {
                return value;
            }
        }

        return error.NoSuchHuffmanCode;
    }

    pub fn readLiteralBits(self: *HuffmanReader, bitsNeeded: u8) !u32 {
        var bits: u32 = 0;

        var i: usize = 0;
        while (i < bitsNeeded) : (i += 1) {
            bits = (bits << 1) | (try self.readBit());
        }

        return bits;
    }

    /// This function implements T.81 section F1.2.1, Huffman encoding of DC coefficients.
    pub fn readMagnitudeCoded(self: *HuffmanReader, magnitude: u5) !i32 {
        if (magnitude == 0)
            return 0;

        const bits = try self.readLiteralBits(magnitude);

        // The sign of the read bits value.
        const bits_sign = (bits >> (magnitude - 1)) & 1;
        // The mask for clearing the sign bit.
        const bits_mask = (@as(u32, 1) << (magnitude - 1)) - 1;
        // The bits without the sign bit.
        const unsigned_bits = bits & bits_mask;

        // The magnitude base value. This is -2^n+1 when bits_sign == 0, and
        // 2^(n-1) when bits_sign == 1.
        const base = if (bits_sign == 0)
            -(@as(i32, 1) << magnitude) + 1
        else
            (@as(i32, 1) << (magnitude - 1));

        return base + @bitCast(i32, unsigned_bits);
    }
};

const Component = struct {
    id: u8,
    horizontal_sampling_factor: u4,
    vertical_sampling_factor: u4,
    quantization_table_id: u8,

    pub fn read(reader: ImageReader) !Component {
        const component_id = try reader.readByte();
        const sampling_factors = try reader.readByte();
        const quantization_table_id = try reader.readByte();

        const horizontal_sampling_factor = @intCast(u4, sampling_factors >> 4);
        const vertical_sampling_factor = @intCast(u4, sampling_factors & 0xF);

        if (horizontal_sampling_factor < 1 or horizontal_sampling_factor > 4) {
            return error.InvalidSamplingFactor;
        }

        if (vertical_sampling_factor < 1 or vertical_sampling_factor > 4) {
            return error.InvalidSamplingFactor;
        }

        return Component{
            .id = component_id,
            .horizontal_sampling_factor = horizontal_sampling_factor,
            .vertical_sampling_factor = vertical_sampling_factor,
            .quantization_table_id = quantization_table_id,
        };
    }
};

const FrameHeader = struct {
    allocator: Allocator,

    sample_precision: u8,
    row_count: u16,
    samples_per_row: u16,

    components: []Component,

    pub fn read(allocator: Allocator, reader: ImageReader) !FrameHeader {
        var segment_size = try reader.readIntBig(u16);
        if (JPEG_DEBUG) std.debug.print("StartOfFrame: frame size = 0x{X}\n", .{segment_size});
        segment_size -= 2;

        const sample_precision = try reader.readByte();
        const row_count = try reader.readIntBig(u16);
        const samples_per_row = try reader.readIntBig(u16);

        const component_count = try reader.readByte();

        if (component_count != 1 and component_count != 3) {
            return error.InvalidComponentCount;
        }

        if (JPEG_DEBUG) std.debug.print("  {}x{}, precision={}, {} components\n", .{ samples_per_row, row_count, sample_precision, component_count });

        segment_size -= 6;

        var components = try allocator.alloc(Component, component_count);
        errdefer allocator.free(components);

        if (JPEG_VERY_DEBUG) std.debug.print("  Components:\n", .{});
        var i: usize = 0;
        while (i < component_count) : (i += 1) {
            components[i] = try Component.read(reader);
            segment_size -= 3;

            if (JPEG_VERY_DEBUG) {
                std.debug.print("    ID={}, Vfactor={}, Hfactor={} QtableID={}\n", .{
                    components[i].id, components[i].vertical_sampling_factor, components[i].horizontal_sampling_factor, components[i].quantization_table_id,
                });
            }
        }

        std.debug.assert(segment_size == 0);

        return FrameHeader{
            .allocator = allocator,
            .sample_precision = sample_precision,
            .row_count = row_count,
            .samples_per_row = samples_per_row,
            .components = components,
        };
    }

    pub fn deinit(self: *FrameHeader) void {
        self.allocator.free(self.components);
    }
};

const ScanComponentSpec = struct {
    component_selector: u8,
    dc_table_selector: u4,
    ac_table_selector: u4,

    pub fn read(reader: ImageReader) !ScanComponentSpec {
        const component_selector = try reader.readByte();
        const entropy_coding_selectors = try reader.readByte();

        const dc_table_selector = @intCast(u4, entropy_coding_selectors >> 4);
        const ac_table_selector = @intCast(u4, entropy_coding_selectors & 0b11);

        if (JPEG_VERY_DEBUG) {
            std.debug.print("    Component spec: selector={}, DC table ID={}, AC table ID={}\n", .{ component_selector, dc_table_selector, ac_table_selector });
        }

        return ScanComponentSpec{
            .component_selector = component_selector,
            .dc_table_selector = dc_table_selector,
            .ac_table_selector = ac_table_selector,
        };
    }
};

const ScanHeader = struct {
    components: [4]?ScanComponentSpec,
    start_of_spectral_selection: u8,
    end_of_spectral_selection: u8,
    approximation_high: u4,
    approximation_low: u4,

    pub fn read(reader: ImageReader) !ScanHeader {
        var segment_size = try reader.readIntBig(u16);
        if (JPEG_DEBUG) std.debug.print("StartOfScan: segment size = 0x{X}\n", .{segment_size});
        segment_size -= 2;

        const component_count = try reader.readByte();
        if (component_count < 1 or component_count > 4) {
            return error.InvalidComponentCount;
        }

        segment_size -= 1;

        var components = [_]?ScanComponentSpec{null} ** 4;

        if (JPEG_VERY_DEBUG) std.debug.print("  Components:\n", .{});
        var i: usize = 0;
        while (i < component_count) : (i += 1) {
            components[i] = try ScanComponentSpec.read(reader);
            segment_size -= 2;
        }

        const start_of_spectral_selection = try reader.readByte();
        const end_of_spectral_selection = try reader.readByte();

        if (start_of_spectral_selection > 63) {
            return error.InvalidSpectralSelectionValue;
        }

        if (end_of_spectral_selection < start_of_spectral_selection or end_of_spectral_selection > 63) {
            return error.InvalidSpectralSelectionValue;
        }

        // If Ss = 0, then Se = 63.
        if (start_of_spectral_selection == 0 and end_of_spectral_selection != 63) {
            return error.InvalidSpectralSelectionValue;
        }

        segment_size -= 2;
        if (JPEG_VERY_DEBUG) std.debug.print("  Spectral selection: {}-{}\n", .{ start_of_spectral_selection, end_of_spectral_selection });

        const approximation_bits = try reader.readByte();
        const approximation_high = @intCast(u4, approximation_bits >> 4);
        const approximation_low = @intCast(u4, approximation_bits & 0b1111);

        segment_size -= 1;
        if (JPEG_VERY_DEBUG) std.debug.print("  Approximation bit position: high={} low={}\n", .{ approximation_high, approximation_low });

        std.debug.assert(segment_size == 0);

        return ScanHeader{
            .components = components,
            .start_of_spectral_selection = start_of_spectral_selection,
            .end_of_spectral_selection = end_of_spectral_selection,
            .approximation_high = approximation_high,
            .approximation_low = approximation_low,
        };
    }
};

// See figure A.6 in T.81.
const ZigzagOffsets = blk: {
    var offsets: [64]usize = undefined;
    offsets[0] = 0;

    var current_offset: usize = 0;
    var direction: enum { NorthEast, SouthWest } = .NorthEast;
    var i: usize = 1;
    while (i < 64) : (i += 1) {
        switch (direction) {
            .NorthEast => {
                if (current_offset < 8) {
                    // Hit top edge
                    current_offset += 1;
                    direction = .SouthWest;
                } else if (current_offset % 8 == 7) {
                    // Hit right edge
                    current_offset += 8;
                    direction = .SouthWest;
                } else {
                    current_offset -= 7;
                }
            },
            .SouthWest => {
                if (current_offset >= 56) {
                    // Hit bottom edge
                    current_offset += 1;
                    direction = .NorthEast;
                } else if (current_offset % 8 == 0) {
                    // Hit left edge
                    current_offset += 8;
                    direction = .NorthEast;
                } else {
                    current_offset += 7;
                }
            },
        }

        if (current_offset >= 64) {
            @compileError(std.fmt.comptimePrint("ZigzagOffsets: Hit offset {} (>= 64) at index {}!\n", .{ current_offset, i }));
        }

        offsets[i] = current_offset;
    }

    break :blk offsets;
};

// The precalculated IDCT multipliers. This is possible because the only part of
// the IDCT calculation that changes between runs is the coefficients.
const IDCTMultipliers = blk: {
    var multipliers: [8][8][8][8]f32 = undefined;
    @setEvalBranchQuota(18086);

    var y: usize = 0;
    while (y < 8) : (y += 1) {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            var u: usize = 0;
            while (u < 8) : (u += 1) {
                var v: usize = 0;
                while (v < 8) : (v += 1) {
                    const C_u: f32 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
                    const C_v: f32 = if (v == 0) 1.0 / @sqrt(2.0) else 1.0;

                    const x_cosine = @cos(((2 * @intToFloat(f32, x) + 1) * @intToFloat(f32, u) * std.math.pi) / 16.0);
                    const y_cosine = @cos(((2 * @intToFloat(f32, y) + 1) * @intToFloat(f32, v) * std.math.pi) / 16.0);
                    const uv_value = C_u * C_v * x_cosine * y_cosine;
                    multipliers[y][x][u][v] = uv_value;
                }
            }
        }
    }

    break :blk multipliers;
};

const Scan = struct {
    pub fn performScan(frame: *Frame, reader: ImageReader) !void {
        const scan_header = try ScanHeader.read(reader);

        var prediction_values = [3]i12{ 0, 0, 0 };
        var huffman_reader = HuffmanReader.init(reader);
        var mcu_id: usize = 0;
        while (mcu_id < frame.mcu_storage.len) : (mcu_id += 1) {
            try Scan.decodeMCU(frame, scan_header, mcu_id, &huffman_reader, &prediction_values);
        }
    }

    fn decodeMCU(frame: *Frame, scan_header: ScanHeader, mcu_id: usize, reader: *HuffmanReader, prediction_values: *[3]i12) !void {
        for (scan_header.components) |maybe_component, component_id| {
            _ = component_id;
            if (maybe_component == null)
                break;

            try Scan.decodeMCUComponent(frame, maybe_component.?, mcu_id, reader, prediction_values);
        }
    }

    fn decodeMCUComponent(frame: *Frame, component: ScanComponentSpec, mcu_id: usize, reader: *HuffmanReader, prediction_values: *[3]i12) !void {
        // The encoder might reorder components or omit one if it decides that the
        // file size can be reduced that way. Therefore we need to select the correct
        // destination for this component.
        const component_destination = blk: {
            for (frame.frame_header.components) |frame_component, i| {
                if (frame_component.id == component.component_selector) {
                    break :blk i;
                }
            }

            return error.UnknownComponentInScan;
        };

        const mcu = &frame.mcu_storage[mcu_id][component_destination];

        // Decode the DC coefficient
        if (frame.dc_huffman_tables[component.dc_table_selector] == null)
            return error.NonexistentDCHuffmanTableReferenced;

        reader.setHuffmanTable(&frame.dc_huffman_tables[component.dc_table_selector].?);

        const dc_coefficient = try Scan.decodeDCCoefficient(reader, &prediction_values[component_destination]);
        mcu[0] = dc_coefficient;

        // Decode the AC coefficients
        if (frame.ac_huffman_tables[component.ac_table_selector] == null)
            return error.NonexistentACHuffmanTableReferenced;

        reader.setHuffmanTable(&frame.ac_huffman_tables[component.ac_table_selector].?);

        try Scan.decodeACCoefficients(reader, mcu);
    }

    fn decodeDCCoefficient(reader: *HuffmanReader, prediction: *i12) !i12 {
        const maybe_magnitude = try reader.readCode();
        if (maybe_magnitude > 11) return error.InvalidDCMagnitude;
        const magnitude = @intCast(u4, maybe_magnitude);

        const diff = @intCast(i12, try reader.readMagnitudeCoded(magnitude));
        const dc_coefficient = diff + prediction.*;
        prediction.* = dc_coefficient;

        return dc_coefficient;
    }

    fn decodeACCoefficients(reader: *HuffmanReader, mcu: *Frame.MCU) !void {
        var ac: usize = 1;
        var did_see_eob = false;
        while (ac < 64) : (ac += 1) {
            if (did_see_eob) {
                mcu[ZigzagOffsets[ac]] = 0;
                continue;
            }

            const zero_run_length_and_magnitude = try reader.readCode();
            // 00 == EOB
            if (zero_run_length_and_magnitude == 0x00) {
                did_see_eob = true;
                mcu[ZigzagOffsets[ac]] = 0;
                continue;
            }

            const zero_run_length = zero_run_length_and_magnitude >> 4;

            const maybe_magnitude = zero_run_length_and_magnitude & 0xF;
            if (maybe_magnitude > 10) return error.InvalidACMagnitude;
            const magnitude = @intCast(u4, maybe_magnitude);

            const ac_coefficient = @intCast(i11, try reader.readMagnitudeCoded(magnitude));

            var i: usize = 0;
            while (i < zero_run_length) : (i += 1) {
                mcu[ZigzagOffsets[ac]] = 0;
                ac += 1;
            }

            mcu[ZigzagOffsets[ac]] = ac_coefficient;
        }
    }
};

const Frame = struct {
    allocator: Allocator,
    frame_header: FrameHeader,
    quantization_tables: *[4]?QuantizationTable,
    dc_huffman_tables: [2]?HuffmanTable,
    ac_huffman_tables: [2]?HuffmanTable,
    mcu_storage: [][MAX_COMPONENTS]MCU,

    const MCU = [64]i32;

    const MAX_COMPONENTS = 3;

    pub fn read(allocator: Allocator, quantization_tables: *[4]?QuantizationTable, reader: ImageReader, seek_stream: ImageSeekStream) !Frame {
        var frame_header = try FrameHeader.read(allocator, reader);
        const mcu_count = Frame.calculateMCUCountInFrame(&frame_header);

        const mcu_storage = try allocator.alloc([MAX_COMPONENTS]MCU, mcu_count);

        var self = Frame{
            .allocator = allocator,
            .frame_header = frame_header,
            .quantization_tables = quantization_tables,
            .dc_huffman_tables = [_]?HuffmanTable{null} ** 2,
            .ac_huffman_tables = [_]?HuffmanTable{null} ** 2,
            .mcu_storage = mcu_storage,
        };
        errdefer self.deinit();

        var marker = try reader.readIntBig(u16);
        while (marker != @enumToInt(Markers.StartOfScan)) : (marker = try reader.readIntBig(u16)) {
            if (JPEG_DEBUG) std.debug.print("Frame: Parsing marker value: 0x{X}\n", .{marker});

            switch (@intToEnum(Markers, marker)) {
                .DefineHuffmanTables => {
                    try self.parseDefineHuffmanTables(reader);
                },
                else => {
                    return error.UnknownMarkerInFrame;
                },
            }
        }

        while (marker == @enumToInt(Markers.StartOfScan)) : (marker = try reader.readIntBig(u16)) {
            try self.parseScan(reader);
        }

        // Undo the last marker read
        try seek_stream.seekBy(-2);

        // Dequantize
        try self.dequantize();

        return self;
    }

    pub fn deinit(self: *Frame) void {
        for (self.dc_huffman_tables) |*maybe_huffman_table| {
            if (maybe_huffman_table.*) |*huffman_table| {
                huffman_table.deinit();
            }
        }

        for (self.ac_huffman_tables) |*maybe_huffman_table| {
            if (maybe_huffman_table.*) |*huffman_table| {
                huffman_table.deinit();
            }
        }

        self.frame_header.deinit();
        self.allocator.free(self.mcu_storage);
    }

    fn parseDefineHuffmanTables(self: *Frame, reader: ImageReader) !void {
        var segment_size = try reader.readIntBig(u16);
        if (JPEG_DEBUG) std.debug.print("DefineHuffmanTables: segment size = 0x{X}\n", .{segment_size});
        segment_size -= 2;

        while (segment_size > 0) {
            const class_and_destination = try reader.readByte();
            const table_class = class_and_destination >> 4;
            const table_destination = class_and_destination & 0b1;

            const huffman_table = try HuffmanTable.read(self.allocator, table_class, reader);

            if (table_class == 0) {
                if (self.dc_huffman_tables[table_destination]) |*old_huffman_table| {
                    old_huffman_table.deinit();
                }
                self.dc_huffman_tables[table_destination] = huffman_table;
            } else {
                if (self.ac_huffman_tables[table_destination]) |*old_huffman_table| {
                    old_huffman_table.deinit();
                }
                self.ac_huffman_tables[table_destination] = huffman_table;
            }

            if (JPEG_DEBUG) std.debug.print("  Table with class {} installed at {}\n", .{ table_class, table_destination });

            // Class+Destination + code counts + code table
            segment_size -= 1 + 16 + @intCast(u16, huffman_table.code_map.count());
        }
    }

    fn calculateMCUCountInFrame(frame_header: *FrameHeader) usize {
        // FIXME: This is very naive and probably only works for Baseline DCT.
        const sample_count = @as(usize, frame_header.row_count) * @as(usize, frame_header.samples_per_row);
        return (sample_count / 64) + (if (sample_count % 64 != 0) @as(u1, 1) else @as(u1, 0));
    }

    fn parseScan(self: *Frame, reader: ImageReader) !void {
        try Scan.performScan(self, reader);
    }

    fn dequantize(self: *Frame) !void {
        var mcu_id: usize = 0;
        while (mcu_id < self.mcu_storage.len) : (mcu_id += 1) {
            for (self.frame_header.components) |component, component_id| {
                const mcu = &self.mcu_storage[mcu_id][component_id];

                if (self.quantization_tables[component.quantization_table_id]) |quantization_table| {
                    var sample_id: usize = 0;
                    while (sample_id < 64) : (sample_id += 1) {
                        mcu[sample_id] = mcu[sample_id] * quantization_table.Q8[sample_id];
                    }
                } else return error.UnknownQuantizationTableReferenced;
            }
        }
    }

    pub fn renderToPixels(self: *Frame, pixels: *color.PixelStorage) !void {
        switch (self.frame_header.components.len) {
            1 => try self.renderToPixelsGrayscale(pixels.Grayscale8),
            3 => try self.renderToPixelsRgb(pixels.Rgb24),
            else => unreachable,
        }
    }

    fn renderToPixelsGrayscale(self: *Frame, pixels: []color.Grayscale8) !void {
        _ = self;
        _ = pixels;
        return error.NotImplemented;
    }

    fn renderToPixelsRgb(self: *Frame, pixels: []color.Rgb24) !void {
        var width = self.frame_header.samples_per_row;
        var mcu_id: usize = 0;
        while (mcu_id < self.mcu_storage.len) : (mcu_id += 1) {
            const mcus_per_row = width / 8;
            // The 8x8 block offsets, from left and top.
            const block_x = (mcu_id % mcus_per_row);
            const block_y = (mcu_id / mcus_per_row);

            const mcu_Y = &self.mcu_storage[mcu_id][0];
            const mcu_Cb = &self.mcu_storage[mcu_id][1];
            const mcu_Cr = &self.mcu_storage[mcu_id][2];

            var y: u4 = 0;
            while (y < 8) : (y += 1) {
                var x: u4 = 0;
                while (x < 8) : (x += 1) {
                    const reconstructed_Y = idct(mcu_Y, @intCast(u3, x), @intCast(u3, y), mcu_id, 0);
                    const reconstructed_Cb = idct(mcu_Cb, @intCast(u3, x), @intCast(u3, y), mcu_id, 1);
                    const reconstructed_Cr = idct(mcu_Cr, @intCast(u3, x), @intCast(u3, y), mcu_id, 2);

                    const Y = @intToFloat(f32, reconstructed_Y);
                    const Cb = @intToFloat(f32, reconstructed_Cb);
                    const Cr = @intToFloat(f32, reconstructed_Cr);

                    const Co_red = 0.299;
                    const Co_green = 0.587;
                    const Co_blue = 0.114;

                    const R = Cr * (2 - 2 * Co_red) + Y;
                    const B = Cb * (2 - 2 * Co_blue) + Y;
                    const G = (Y - Co_blue * B - Co_red * R) / Co_green;

                    pixels[(((block_y * 8) + y) * width) + (block_x * 8) + x] = .{
                        .R = @floatToInt(u8, std.math.clamp(R + 128.0, 0.0, 255.0)),
                        .G = @floatToInt(u8, std.math.clamp(G + 128.0, 0.0, 255.0)),
                        .B = @floatToInt(u8, std.math.clamp(B + 128.0, 0.0, 255.0)),
                    };
                }
            }
        }
    }

    fn idct(mcu: *const MCU, x: u3, y: u3, mcu_id: usize, component_id: usize) i8 {
        var reconstructed_pixel: f32 = 0.0;

        var u: usize = 0;
        while (u < 8) : (u += 1) {
            var v: usize = 0;
            while (v < 8) : (v += 1) {
                const mcu_value = mcu[v * 8 + u];
                reconstructed_pixel += IDCTMultipliers[y][x][u][v] * @intToFloat(f32, mcu_value);
            }
        }

        const scaled_pixel = @round(reconstructed_pixel / 4.0);
        if (JPEG_DEBUG) {
            if (scaled_pixel < -128.0 or scaled_pixel > 127.0) {
                std.debug.print("Pixel at mcu={} x={} y={} component_id={} is out of bounds with DCT: {d}!\n", .{ mcu_id, x, y, component_id, scaled_pixel });
            }
        }

        return @floatToInt(i8, std.math.clamp(scaled_pixel, -128.0, 127.0));
    }
};

pub const JPEG = struct {
    frame: ?Frame = null,
    allocator: Allocator,
    quantization_tables: [4]?QuantizationTable,

    pub fn init(allocator: Allocator) JPEG {
        return .{
            .allocator = allocator,
            .quantization_tables = [_]?QuantizationTable{null} ** 4,
        };
    }

    pub fn deinit(self: *JPEG) void {
        if (self.frame) |*frame| {
            frame.deinit();
        }
    }

    fn parseDefineQuantizationTables(self: *JPEG, reader: ImageReader) !void {
        var segment_size = try reader.readIntBig(u16);
        if (JPEG_DEBUG) std.debug.print("DefineQuantizationTables: segment size = 0x{X}\n", .{segment_size});
        segment_size -= 2;

        while (segment_size > 0) {
            const precision_and_destination = try reader.readByte();
            const table_precision = precision_and_destination >> 4;
            const table_destination = precision_and_destination & 0b11;

            const quantization_table = try QuantizationTable.read(table_precision, reader);
            switch (quantization_table) {
                .Q8 => segment_size -= 64 + 1,
                .Q16 => segment_size -= 128 + 1,
            }

            self.quantization_tables[table_destination] = quantization_table;
            if (JPEG_DEBUG) std.debug.print("  Table with precision {} installed at {}\n", .{ table_precision, table_destination });
        }
    }

    fn initializePixels(self: *JPEG, pixels_opt: *?color.PixelStorage) !void {
        if (self.frame) |frame| {
            var pixel_format: PixelFormat = undefined;
            switch (frame.frame_header.components.len) {
                1 => pixel_format = .Grayscale8,
                3 => pixel_format = .Rgb24,
                else => unreachable,
            }

            const pixel_count = @intCast(usize, frame.frame_header.samples_per_row) * @intCast(usize, frame.frame_header.row_count);
            pixels_opt.* = try color.PixelStorage.init(self.allocator, pixel_format, pixel_count);
        } else return error.FrameDoesNotExist;
    }

    pub fn read(self: *JPEG, reader: ImageReader, seek_stream: ImageSeekStream, pixels_opt: *?color.PixelStorage) !Frame {
        _ = pixels_opt;
        const jfif_header = JFIFHeader.read(reader, seek_stream) catch |err| switch (err) {
            error.App0MarkerDoesNotExist, error.JfifIdentifierNotSet, error.ThumbnailImagesUnsupported, error.ExtraneousApplicationMarker => return errors.ImageError.InvalidMagicHeader,
            else => |e| return e,
        };
        _ = jfif_header;

        errdefer {
            if (pixels_opt.*) |pixels| {
                pixels.deinit(self.allocator);
                pixels_opt.* = null;
            }
        }

        var marker = try reader.readIntBig(u16);
        while (marker != @enumToInt(Markers.EndOfImage)) : (marker = try reader.readIntBig(u16)) {
            if (JPEG_DEBUG) std.debug.print("Parsing marker value: 0x{X}\n", .{marker});

            if (marker >= @enumToInt(Markers.Application0) and marker < @enumToInt(Markers.Application0) + 16) {
                if (JPEG_DEBUG) std.debug.print("Skipping application data segment\n", .{});
                const application_data_length = try reader.readIntBig(u16);
                try seek_stream.seekBy(application_data_length - 2);
                continue;
            }

            switch (@intToEnum(Markers, marker)) {
                .SOF0 => {
                    if (self.frame != null) {
                        return error.UnsupportedMultiframe;
                    }

                    self.frame = try Frame.read(self.allocator, &self.quantization_tables, reader, seek_stream);
                    try self.initializePixels(pixels_opt);
                    try self.frame.?.renderToPixels(&pixels_opt.*.?);
                },

                .SOF1 => return error.UnsupportedFrameFormat,
                .SOF2 => return error.UnsupportedFrameFormat,
                .SOF3 => return error.UnsupportedFrameFormat,
                .SOF5 => return error.UnsupportedFrameFormat,
                .SOF6 => return error.UnsupportedFrameFormat,
                .SOF7 => return error.UnsupportedFrameFormat,
                .SOF9 => return error.UnsupportedFrameFormat,
                .SOF10 => return error.UnsupportedFrameFormat,
                .SOF11 => return error.UnsupportedFrameFormat,
                .SOF13 => return error.UnsupportedFrameFormat,
                .SOF14 => return error.UnsupportedFrameFormat,
                .SOF15 => return error.UnsupportedFrameFormat,

                .DefineQuantizationTables => {
                    try self.parseDefineQuantizationTables(reader);
                },

                .Comment => {
                    if (JPEG_DEBUG) std.debug.print("Skipping comment segment\n", .{});

                    const comment_length = try reader.readIntBig(u16);
                    try seek_stream.seekBy(comment_length - 2);
                },

                else => {
                    return error.UnknownMarker;
                },
            }
        }

        return if (self.frame) |frame| frame else error.FrameHeaderDoesNotExist;
    }

    // Format interface

    pub fn formatInterface() FormatInterface {
        return FormatInterface{
            .format = @ptrCast(FormatInterface.FormatFn, format),
            .formatDetect = @ptrCast(FormatInterface.FormatDetectFn, formatDetect),
            .readForImage = @ptrCast(FormatInterface.ReadForImageFn, readForImage),
            .writeForImage = @ptrCast(FormatInterface.WriteForImageFn, writeForImage),
        };
    }

    fn format() ImageFormat {
        return ImageFormat.Jpeg;
    }

    fn formatDetect(reader: ImageReader, seek_stream: ImageSeekStream) !bool {
        const maybe_start_of_image = try reader.readIntBig(u16);
        if (maybe_start_of_image != @enumToInt(Markers.StartOfImage)) {
            return false;
        }

        try seek_stream.seekTo(6);
        var identifier_buffer: [4]u8 = undefined;
        _ = try reader.read(identifier_buffer[0..]);

        return std.mem.eql(u8, identifier_buffer[0..], "JFIF");
    }

    fn readForImage(allocator: Allocator, reader: ImageReader, seek_stream: ImageSeekStream, pixels_opt: *?color.PixelStorage) !ImageInfo {
        var jpeg = JPEG.init(allocator);
        defer jpeg.deinit();

        const frame = try jpeg.read(reader, seek_stream, pixels_opt);
        return ImageInfo{
            .width = frame.frame_header.samples_per_row,
            .height = frame.frame_header.row_count,
        };
    }

    fn writeForImage(allocator: Allocator, write_stream: image.ImageWriterStream, seek_stream: ImageSeekStream, pixels: color.PixelStorage, save_info: image.ImageSaveInfo) !void {
        _ = allocator;
        _ = write_stream;
        _ = seek_stream;
        _ = pixels;
        _ = save_info;
        @panic("TODO: Implement JPEG writing! (maybe not...)");
    }
};