

Header :: struct {
    magic: u16;
    compression_method: Compression_Type;
    flags: File_Flag;
    timestamp: u32; // Unix timestamp
    extra_flags: Extra_Flag;
    operating_system_id: Operating_System_Type;

    // Optional Feilds
    extra_length: u16; // If non-zero, then extra_feild is a valid pointer to the extra data payload
    extra_feild: *u8;  // extra_feild is a pointer to allocated data, and its the uses job to free it
                       // This is the raw bytes of the extra feild. // TODO: Consider actually paring this...

    name: string;      // If FNAME is set in the flags, this is a valid string of the original filename, otherwise null, is an allocated string and needs to be freed if non null
    comment: string;   // If FCOMMENT is set in the flags, this is a valid string of the given comment, otherwise null, is an allocated string and needs to be freed if non null

    crc16: u16;        // If FHCRC is set in the flags, this will be the given crc16 result
}

// TODO: Implement checking and parsing the footer
Footer :: struct {
    crc32: u32; // This is the Cyclic Redundancy Check value of the uncompressed data commputed
                // according to CRC-32 algorithm used in the ISO 3309 standard
    size: u32;  // This is the size of the original (uncompressed) input data modulo 2^32
}

Compression_Type :: enum u8 {
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

File_Flag :: enum u8 {
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

Extra_Flag :: enum u8 {
    MAXIMUM_COMPRESSION :: 2; // The compressor used maximum compression, slowest algorithm
    FASTEST_COMPRESSION :: 4; // The compressor used fastest algorithm
}

Operating_System_Type :: enum u8 {
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

// NOTE:
// This whole file is pedantic about bounds checks, it
// could probably be redone and minimize those checks to
// only places where we dont yet know how many bytes to
// read forward.
//
//     - Steven Savold (July 16th, 2023)
//

// TODO:
// We probably should restructure this whole module to use mutliple files
// Im imagining a deflate.jai, inflate.jai (for when we evenually do compression),
// and gzip.jai (and maybe a zip.jai if we want to tackle zip formats too). 
// This way we split the formats apart and can just #load everything in the 
// module.jai file.
//


unzip :: (content: [] u8) -> (success: bool, unziped_content: [] u8, header: Header, footer: Footer) {
    success, header, bytes_read := parse_gzip_header(content);
    if !success {
        return false, .[], .{}, .{};
    }

    body := array_view(content, bytes_read);
    success=, inflated_content := inflate(body);

    return true, inflated_content, header, .{}; // TODO: Footer is not being parsed yet
}

unzip :: (filename: string) -> (success: bool, unziped_content: [] u8, header: Header, footer: Footer) {
    content, success := read_entire_file(filename, false, true);
    if !success {
        log_error("GZIP   [ERROR]: unable to read file '%'", filename);
        return false, .[], .{}, .{};
    }

    defer free(content.data); // Make sure to realease the file content once we are done decompressing
    view: [] u8;
    view.data  = content.data;
    view.count = content.count;

    success=, unzipped_content, header, footer := unzip(view);
    return success, unzipped_content, header, footer;
}



#scope_file
magic_number: u16 : 0x1f_8b;

// Parses the header of a Gzip file, header and body_start are only valid if success is true.
// body_start represents the first byte after the payload ended.
parse_gzip_header :: (content: [] u8) -> (success: bool, header: Header, bytes_read: s64) {
    bytes_read := 0;
    if content.count < 10 {
        log_error("GZIP   [ERROR]: file was not big enough to uncompress");
        return false, .{}, bytes_read;
    }

    byte := content.data;
    using header: Header;

    // TODO: If this is the last use of big_endian_to_little_endian() consider just removing the function and reading the bytes piecemeal
    magic = big_endian_to_little_endian(byte, type_of(magic));
    byte += size_of(type_of(magic));
    bytes_read += size_of(type_of(magic));

    if magic != magic_number {
        log_error("GZIP   [ERROR]: provided file was not a gzip file");
        return false, .{}, bytes_read;
    }

    compression_method = xx <<byte;
    byte += size_of(type_of(compression_method));
    bytes_read += size_of(type_of(compression_method));

    if compression_method != .DEFLATE {
        log_error("GZIP   [ERROR]: this parser cannot decompress gzip files using this compression method");
    }

    flags = xx <<byte;
    byte += size_of(type_of(flags));
    bytes_read += size_of(type_of(flags));

    if flags & (.RESERVED_0 | .RESERVED_1 | .RESERVED_2) {
        log_error("GZIP   [ERROR]: one or more reserved flags were found to be set, either this parser is out of date, or this file is invalid");
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
            log_error("GZIP   [ERROR]: file was not big enough to uncompress");
            return false, .{}, bytes_read;
        }

        extra_length = big_endian_to_little_endian(byte, type_of(extra_length)); // TODO: is this incorrect? timestamp was little endian...
        byte += size_of(type_of(extra_length));
        bytes_read += size_of(type_of(extra_length));

        if extra_length > 0 {
            if (bytes_read + extra_length) > content.count {
                log_error("GZIP   [ERROR]: file was not big enough to uncompress");
                return false, .{}, bytes_read;
            }
            extra_feild = alloc(extra_length);
            memcpy(extra_feild, byte, extra_length);
            byte += extra_length;
            bytes_read += extra_length;
        } else {
            log("GZIP [WARNING]: extra length flag was set, but the extra length feild was 0");
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
            log_error("GZIP   [ERROR]: FNAME flag was set, but we ran out of file data before the name could finish being read"); // TODO: This error message could probably be worded better...
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
            log_error("GZIP   [ERROR]: FCOMMENT flag was set, but we ran out of file data before the comment could finish being read"); // TODO: This error message could probably be worded better...
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
            log_error("GZIP   [ERROR]: file was not big enough to uncompress");
            return false, .{}, bytes_read;
        }

        // TODO: If this parses correctly we actually should check to make sure the crc 
        // passes (maybe add a flag to disable crc checks)
        crc16 = big_endian_to_little_endian(byte, type_of(crc16));
        byte += size_of(type_of(crc16));
        bytes_read += size_of(type_of(crc16));
    }

    return true, header, bytes_read;
}





#load "huffman.jai";
#load "deflate.jai";

#import "Basic";
#import "File";
