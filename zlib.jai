
Zlib_Header :: struct {
    compression_method: Zlib_Compression_Method;

    // https://www.rfc-editor.org/rfc/rfc1950 [section 2.2]
    // For compression_method == 8 CINFO represents the the base-2 logarithm of the LZ77 window size, minus 8 (CINFO=7 indicates a 32K window size).
    // Values of CINFO above 7 are not allowed in thie version of the specification. CINFO is not defined in thie specification for CM not equal to 8.
    compression_info: u8;

    preset_dictionary: bool;
    compression_level: Zlib_Compression_Level;

    dictionary_id: u32;
}

Zlib_Compression_Method :: enum u8 {
    None :: 0;
    Reserved_0 :: 1 << 0; // 1
    Reserved_1 :: 1 << 1; // 2
    Reserved_2 :: 1 << 2; // 4
    Deflate    :: 1 << 3; // 8
}

Zlib_Compression_Level :: enum u8 {
    FASTEST :: 0;
    FAST    :: 1;
    DEFAULT :: 2;
    MAXIMUM :: 3;
}


parse_zlib_header :: (compressed_content: [] u8) -> success: bool, header: Zlib_Header, bytes_read: s64 {
    header: Zlib_Header;
    bytes_read := 0;

    if compressed_content.count < 2 {
        log_error("ZLIB      [ERROR]: file was not long enough to read header");
        return false, header, bytes_read;
    }

    // https://www.rfc-editor.org/rfc/rfc1950 [section 2.2]
    // The FCHECK value must be such that CMF and FLG, when viewed as
    // a 16-bit unsigned integer stored in MSB order (CMF*256 + FLG),
    // is a multiple of 31.
    two_byte_header: u16 = cast(u16) (((cast(u16)(compressed_content[0])) * 256) + (cast(u16)(compressed_content[1])));
    bytes_read += 2;

    if two_byte_header % 31 != 0 {
        log_error("ZLIB      [ERROR]: Could not decompress content, header was not in zlib format");
        return false, header, bytes_read;
    }

    header.compression_method = xx ( compressed_content[0] & 0b0000_1111);
    header.compression_info   =    ((compressed_content[0] & 0b1111_0000) >> 4);
    header.preset_dictionary  = xx ( compressed_content[1] & 0b0010_0000);
    header.compression_level  = xx ((compressed_content[1] & 0b1100_0000) >> 6);

    // The only supported compression method for the zlib format as of writing this is Deflate.
    // The code will need to be updated if this changes
    if header.compression_method != .Deflate {
        log_error("ZLIB      [ERROR]: could not decompress zlib file, unsupported compression method (%)", header.compression_method);
        return false, header, bytes_read;
    }

    if header.preset_dictionary {
        if compressed_content.count < 6 {
            log_error("ZLIB      [ERROR]: file not long enough to read dictionary id");
            return false, header, bytes_read;
        }
        memcpy(*header.dictionary_id, compressed_content.data + 2, 4); // read the 4 bytes after the 2 header bytes if FDICT is set
        bytes_read += 4;
    }

    return true, header, bytes_read;
}

#scope_file
#import "Basic";
