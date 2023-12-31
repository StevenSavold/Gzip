

// NOTE:
// This whole file is pedantic about bounds checks, it
// could probably be redone and minimize those checks to
// only places where we dont yet know how many bytes to
// read forward.
//
//     - Steven Savold (July 16th, 2023)
//

Gzip_Header :: struct {
    magic: u16;
    compression_method: Gzip_Compression_Type;
    flags: Gzip_File_Flag;
    timestamp: u32; // Unix timestamp
    extra_flags: Gzip_Extra_Flag;
    operating_system_id: Gzip_Operating_System_Type;

    // Optional Feilds
    extra_length: u16; // If non-zero, then extra_feild is a valid pointer to the extra data payload
    extra_feild: *u8;  // extra_feild is a pointer to allocated data, and its the uses job to free it
                       // This is the raw bytes of the extra feild. // TODO: Consider actually paring this...

    name: string;      // If FNAME is set in the flags, this is a valid string of the original filename, otherwise null, is an allocated string and needs to be freed if non null
    comment: string;   // If FCOMMENT is set in the flags, this is a valid string of the given comment, otherwise null, is an allocated string and needs to be freed if non null

    crc16: u16;        // If FHCRC is set in the flags, this will be the given crc16 result
}

Gzip_Footer :: struct {
    crc32: u32; // This is the Cyclic Redundancy Check value of the uncompressed data commputed
                // according to CRC-32 algorithm used in the ISO 3309 standard
    size: u32;  // This is the size of the original (uncompressed) input data modulo 2^32
}

Gzip_Compression_Type :: enum u8 {
    RESERVED_0 :: 0x00;
    RESERVED_1 :: 0x01;
    RESERVED_2 :: 0x02;
    RESERVED_3 :: 0x03;
    RESERVED_4 :: 0x04;
    RESERVED_5 :: 0x05;
    RESERVED_6 :: 0x06;
    RESERVED_7 :: 0x07;

    DEFLATE    :: 0x08;
}

Gzip_File_Flag :: enum u8 {
    FTEXT    :: 0x01;  // If set the uncompressed data needs to be treated as text instead of
                       // binary data. This flag hints end-of-line conversion for cross-platform
                       // text files but does not enforce it

    FHCRC    :: 0x02;  // The file contains a header checksum (CRC-16)
    FEXTRA   :: 0x04;  // The file contains extra feilds
    FNAME    :: 0x08;  // The file contains an original file name string
    FCOMMENT :: 0x10;  // The file contains comment

    RESERVED_0 :: 0x20; // The reserved bits must be 0's
    RESERVED_1 :: 0x40;
    RESERVED_2 :: 0x80;
}

Gzip_Extra_Flag :: enum u8 {
    MAXIMUM_COMPRESSION :: 2; // The compressor used maximum compression, slowest algorithm
    FASTEST_COMPRESSION :: 4; // The compressor used fastest algorithm
}

Gzip_Operating_System_Type :: enum u8 {
    FAT          :: 0;
    AMIGA        :: 1;
    VMS          :: 2;
    UNIX         :: 3;
    VM_CMS       :: 4;
    ATARI_TOS    :: 5;
    HPFS         :: 6;
    MACINTOSH    :: 7;
    Z_SYSTEM     :: 8;
    CP_M         :: 9;
    TOPS_20      :: 10;
    NTFS         :: 11;
    QDOS         :: 12;
    ACORN_RISCOS :: 13;

    UNKNOWN      :: 255;
}


magic_number: u16 : 0x1f_8b;

// Parses the header of a Gzip file, header and bytes_read are only valid if success is true.
parse_gzip_header :: (content: [] u8) -> (success: bool, header: Gzip_Header, bytes_read: s64) {
    bytes_read := 0;
    if content.count < 10 {
        log_error("GZIP      [ERROR]: file was not big enough to uncompress");
        return false, .{}, bytes_read;
    }

    byte := content.data;
    using header: Gzip_Header;

    magic_msb: u16 = xx <<byte;
    magic_lsb: u16 = xx <<(byte + 1);
    magic = (magic_msb << 8) + (magic_lsb << 0);
    byte += size_of(type_of(magic));
    bytes_read += size_of(type_of(magic));

    if magic != magic_number {
        log_error("GZIP      [ERROR]: provided file was not a gzip file");
        return false, .{}, bytes_read;
    }

    compression_method = xx <<byte;
    byte += size_of(type_of(compression_method));
    bytes_read += size_of(type_of(compression_method));

    if compression_method != .DEFLATE {
        log_error("GZIP      [ERROR]: this parser cannot decompress gzip files using this compression method");
    }

    flags = xx <<byte;
    byte += size_of(type_of(flags));
    bytes_read += size_of(type_of(flags));

    if flags & (.RESERVED_0 | .RESERVED_1 | .RESERVED_2) {
        log_error("GZIP      [ERROR]: one or more reserved flags were found to be set, either this parser is out of date, or this file is invalid");
        return false, .{}, bytes_read;
    }

    memcpy(*timestamp, byte, 4);
    byte += size_of(type_of(timestamp));
    bytes_read += size_of(type_of(timestamp));

    extra_flags = xx <<byte;
    byte += size_of(type_of(extra_flags));
    bytes_read += size_of(type_of(extra_flags));

    operating_system_id = xx <<byte;
    byte += size_of(type_of(operating_system_id));
    bytes_read += size_of(type_of(operating_system_id));

    if flags & .FEXTRA {
        if (bytes_read + size_of(type_of(extra_length))) > content.count {
            log_error("GZIP      [ERROR]: file was not big enough to uncompress");
            return false, .{}, bytes_read;
        }

        memcpy(*extra_length, byte, size_of(type_of(extra_length)));
        byte += size_of(type_of(extra_length));
        bytes_read += size_of(type_of(extra_length));

        if extra_length > 0 {
            if (bytes_read + extra_length) > content.count {
                log_error("GZIP      [ERROR]: file was not big enough to uncompress");
                return false, .{}, bytes_read;
            }
            extra_feild = alloc(extra_length);
            memcpy(extra_feild, byte, extra_length);
            byte += extra_length;
            bytes_read += extra_length;
        } else {
            log("GZIP    [WARNING]: extra length flag was set, but the extra length feild was 0");
        }
    }

    if flags & .FNAME {
        len := 0;
        success := false;
        while (bytes_read + len) <= content.count {
            if <<(byte + len) == 0 then {
                success = true;
                break;
            }
            len += 1;
        }

        if !success {
            log_error("GZIP      [ERROR]: FNAME flag was set, but we ran out of file data before the name could finish being read");
            return false, .{}, bytes_read;
        }

        name.data = alloc(len);
        name.count = len;
        memcpy(name.data, byte, name.count);

        byte += len + 1;       // +1 for null terminator
        bytes_read += len + 1; //
    }

    if flags & .FCOMMENT {
        len := 0;
        success := false;
        while (bytes_read + len) <= content.count {
            if <<(byte + len) == 0 then {
                success = true;
                break;
            }
            len += 1;
        }

        if !success {
            log_error("GZIP      [ERROR]: FCOMMENT flag was set, but we ran out of file data before the comment could finish being read");
            return false, .{}, bytes_read;
        }

        comment.data = alloc(len);
        comment.count = len;
        memcpy(comment.data, byte, comment.count);

        byte += len + 1;       // +1 for null terminator
        bytes_read += len + 1; //
    }

    if flags & .FHCRC {
        if (bytes_read + size_of(type_of(crc16))) > content.count {
            log_error("GZIP      [ERROR]: file was not big enough to uncompress");
            return false, .{}, bytes_read;
        }

        // TODO: Check the crc16 here for validity
        memcpy(*crc16, byte, size_of(type_of(crc16)));
        byte += size_of(type_of(crc16));
        bytes_read += size_of(type_of(crc16));
    }

    return true, header, bytes_read;
}

parse_gzip_footer :: (content: [] u8) -> success: bool, footer: Gzip_Footer {
    footer_bytes := array_view(content, content.count - 8); // grab the last 8 bytes of the content

    footer: Gzip_Footer;
    memcpy(*footer.crc32, footer_bytes.data, 4);
    memcpy(*footer.size, footer_bytes.data + 4, 4);

    // TODO: check the crc32 here for validity.
    //

    return true, footer;
}
