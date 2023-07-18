


Parse_State :: struct {
    byte: s64; // The byte offset from the start of the input_buffer
    bit: s8;   // The bit offset from the least signifigant bit of the current byte

    input_buffer: [] u8;
}

Block_Type :: enum u8 {
    NONE    :: 0b00;
    FIXED   :: 0b01;
    DYNAMIC :: 0b10;
    ERROR   :: 0b11;
}


// Returns the value of the bit (1 or 0) at the specified position, then
// increments the position, and does a boundscheck if we crossed a byte
// boundary
get :: (using state: *Parse_State) -> u8, bool {
    output  := (input_buffer[byte] >> bit) & 1;
    success := next(state);

    return output, success;
}

// Moves the parse state one bit "forward", doing a bounds check if a byte
// boundary is passed
next :: (using state: *Parse_State) -> bool {
    bit += 1;
    if bit > 7 {
        bit = 0;
        byte += 1;
        return position_bounds_check(state);
    }

    // We do not need a bounds check if we are not moving a byte forward
    return true;
}

// returns true if the Parse_State's read head is still within the bounds
// of the input_buffer
position_bounds_check :: (using state: *Parse_State) -> bool {
    if byte >= input_buffer.count {
        log_error("GZIP   [ERROR]: unable to parse body, no more bytes to read");
        return false;
    }
    return true;
}


// Decompresses a binary block that is encoded using the deflate specification: https://www.ietf.org/rfc/rfc1951.txt
inflate :: (deflated_content: [] u8) -> (success: bool, inflated_content: [] u8) {
    if deflated_content.count <= 0 {
        log_error("GZIP   [ERROR]: unable to inflate content, input stream had no bytes");
        return false, .[];
    }

    state: Parse_State;
    state.input_buffer = deflated_content;

    output_buffer: [..] u8;

    bfinal: u8;
    while bfinal == 0 {
        bfinal=, success := get(*state);
        if !success return false, .[];

        btype_lsb, success= := get(*state);
        if !success return false, .[];

        btype_msb, success= := get(*state);
        if !success return false, .[];

        btype: Block_Type = xx (btype_msb << 1 | btype_lsb);

        if #complete btype == {
            case .NONE;
                success = parse_block_none(*state, *output_buffer);

            case .FIXED;
                success = parse_block_fixed(*state, *output_buffer);

            case .DYNAMIC;
                success = parse_block_dynamic(*state, *output_buffer);

            case .ERROR;
                log_error("GZIP   [ERROR]: encountered an invalid block type");
                return false, .[];
        }

        if !success {
            log_error("GZIP   [ERROR]: error when paring block type '%'", btype);
            return false, .[];
        }
    }

    return true, output_buffer;
}

parse_block_none :: (state: *Parse_State, output_buffer: *[..] u8) -> success: bool {
    if state.bit { // If we are on a byte boundary, jump to the next one
        state.byte += 1;
        state.bit = 0;

        // dont forget the bounds check we need to do since we crossed a byte boundary
        if !position_bounds_check(state) then return false;
    }

    // TODO: are these bounds checks even in the right place? i feel like we are reading the bytes then looking to see if we overran the buffer...
    len  := big_endian_to_little_endian(state.input_buffer.data + state.byte, u16); // TODO: I think this is wrong, mutli-byte numbers in the spec are little endian!
    state.byte += 2;
    if !position_bounds_check(state) return false;

    nlen := big_endian_to_little_endian(state.input_buffer.data + state.byte, u16); // TODO: I think this is wrong, mutli-byte numbers in the spec are little endian!
    state.byte += 2;
    if !position_bounds_check(state) return false;

    if len != ~nlen {
        log_error("GZIP   [ERROR]: invalid block data, length did not match nlength");
        return false;
    }

    new_state := <<state;
    new_state.byte += len; // Lets pretend we are at the end of the block, are we out of bounds?
    if !position_bounds_check(*new_state) return false;

    for i: 0..len-1 { // -1 because jai arrays are inclusive
        array_add(output_buffer, state.input_buffer[state.byte + i]);
    }

    return true;
}

parse_block_fixed :: (state: *Parse_State, output_buffer: *[..] u8) -> success: bool {
    lengths :: #run create_static_lengths_array();
    success, root := create_huffman_tree(lengths); // We could do this at compile time if we didnt allocate the tree on the heap. It certainly would save needing to make the tree for each FIXED block. but how often are those used and will it really save all that much?
    if !success then return false;
    defer { destroy_huffman_tree(root); }; // If we successfully made the huffman tree, we need to de-allocate it before we leave this scope

    // TODO: Depending on how actually similar the code is between dynamic and static compression, maybe this whole
    //       loop can be in its own function that is shared between the two decompression routines
    while true {
        leaf := find_huffman_code(root, (user_data: *void) -> bit: u8, success: bool {
            bit, success := get(xx user_data);
            return bit, success;
        }, state);

        if leaf == null then return false;

        code := leaf.code;
        if !is_in_alphabet(code) {
            log_error("GZIP   [ERROR]: invalid block data, found an invalid huffman code in block (code: %)", code);
            return false;
        }

        // If we see the end-of-block symbol, we can stop looping, we are done
        if is_end_of_block_symbol(code) then break;

        if is_litteral_byte(code) {
            // write the byte from the code to the output buffer
            array_add(output_buffer, cast(u8)code);
            log("added_byte: %", code); // TODO: remove me
        }
        else if is_length_code(code) {
            success, length := get_length_from_code(code, state);
            if !success then return false;
            log("length: %", length); // TODO: remove me

            // the next 5 bits should be the distance code
            success=, distance_code := accumulate_bits(5, state);
            distance_code = invert_bits(distance_code, 5); // TODO: This seems to be correct, but is it? and if it is, why is reading the other things without this correct?

            if !success then return false;
            log("dist_code: %", distance_code); // TODO: remove me

            if !is_distance_code(xx distance_code) {
                log_error("GZIP   [ERROR]: invalid block data, found invalid distance code (%)", distance_code);
                return false;
            }

            success=, distance := get_distance_from_code(distance_code, state);
            if !success then return false;
            log("distance: %", distance); // TODO: remove me

            success = copy_bytes_from_distance(output_buffer, length, distance);
            if !success then return false;
        }
    }

    return true;
}


copy_bytes_from_distance :: (output_buffer: *[..] u8, length: u16, distance: u16) -> bool {
    copy_start_index: s64 = output_buffer.count - distance;
    if copy_start_index < 0 {
        log_error("GZIP   [ERROR]: unable to copy data, distance too large (count: %, distance: %)", output_buffer.count, distance);
        return false;
    }

    // length is known to not be more then 258
    for i: 0..length-1 // copy the bytes from the start index for the amount of bytes specified
        array_add(output_buffer, (<<output_buffer)[copy_start_index + i]);
    
    return true;
}

// Assumes that code is a valid length code, its on the user to check before calling
get_length_from_code :: (code: s16, state: *Parse_State) -> success: bool, length: u16 {
    table_data := length_data[code - 257];
    success, extra_bits_value := accumulate_bits(table_data.extra_bits, state);
    if !success then return false, 0;

    // because a code of 284 with a length 5, would collide with code 258 (227 + 31 = 258),
    // it was given a separate code (285). So having these values should induce an error
    // when parsing
    if code == 284 && extra_bits_value == 31 {
        log_error("GZIP   [ERROR]: unexpected length extra value 31 for code 284, should have been code 285");
        return false, 0;
    }

    length := table_data.value + extra_bits_value;
    if length > 258 || length < 3 {
        log_error("GZIP   [ERROR]: expected length to be between 3 and 258 (it was: %)", length);
        return false, 0;
    }

    return true, length;
}

// Assumes that code is a valid distance code, its on the user to check before calling
get_distance_from_code :: (code: u16, state: *Parse_State) -> success: bool, distance: u16 {
    table_data := distance_data[code];
    success, extra_bits_value := accumulate_bits(table_data.extra_bits, state);
    if !success then return false, 0;

    distance := table_data.value + extra_bits_value;
    if distance < 1 || distance > 32768 {
        log_error("GZIP   [ERROR]: invalid distance value found (%)", distance);
        return false, 0;
    }

    return true, distance;
}

// Highest value of number_of_bits should be 13, because that is the largest number of extra_bits in the table
accumulate_bits :: (number_of_bits: u8, state: *Parse_State) -> success: bool, value: u16 {
    acc: u16 = 0;
    for i: 0..((cast(s16)number_of_bits)-1) { // -1 because jai for loops are inclusive
        bit, success := get(state);
        if !success then return false, 0;
        if bit then
            acc |= cast(u16)1 << i;
    }

    return true, acc;
}

// TODO: Should we be inverting the bits after reading? or should we just read the the right way the first time?
invert_bits :: (bits: u16, number: u16) -> u16 {
    acc: u16 = 0;
    for i: 0..number-1 {
        inv: u16 = number - i - 1;
        acc |= ((bits >> inv) & 1) << i;
    }
    return acc;
}

parse_block_dynamic :: (state: *Parse_State, output_buffer: *[..] u8) -> bool {
    return false;
}

is_in_alphabet :: (value: s16) -> bool {
    return value >= 0 && value <= 285;
}

is_litteral_byte :: (value: s16) -> bool {
    return value >= 0 && value <= 255;
}

is_end_of_block_symbol :: (value: s16) -> bool {
    return value == 256;
}

is_length_code :: (value: s16) -> bool {
    return value >= 257 && value <= 285;
}

is_distance_code :: (value: s16) -> bool {
    return value >= 0 && value <= 29;
}

// TODO: We might not need this function, re-eval when the restructuring is done
// At the very least this is used to parse the gzip header...
big_endian_to_little_endian :: (big_endian: *void, $T: Type) -> T {
    #assert type_info(T).type == .INTEGER "Type must be an integer type";
    output: T;

    ti := type_info(T);
    for i: 0..ti.runtime_size-1 {
        output |= (cast(T)(<<((cast(*u8)big_endian) + i))) << (((ti.runtime_size - 1) - i) * 8);
    }

    return output;
}


create_static_lengths_array :: () -> [288] u8 {
    output: [288] u8;
    for i:   0..143 output[i] = 8;
    for i: 144..255 output[i] = 9;
    for i: 256..279 output[i] = 7;
    for i: 280..287 output[i] = 8;

    return output;
}

length_data: [29] Table_Data : .[
    .{   3, 0 }, .{   4, 0 }, .{   5, 0 }, .{   6, 0 },
    .{   7, 0 }, .{   8, 0 }, .{   9, 0 }, .{  10, 0 },
    .{  11, 1 }, .{  13, 1 }, .{  15, 1 }, .{  17, 1 },
    .{  19, 2 }, .{  23, 2 }, .{  27, 2 }, .{  31, 2 },
    .{  35, 3 }, .{  43, 3 }, .{  51, 3 }, .{  59, 3 },
    .{  67, 4 }, .{  83, 4 }, .{  99, 4 }, .{ 115, 4 },
    .{ 131, 5 }, .{ 163, 5 }, .{ 195, 5 }, .{ 227, 5 },
    .{ 258, 0 },
];

distance_data: [30] Table_Data : .[
    .{     1,  0 }, .{     2,  0 }, .{     3,  0 },
    .{     4,  0 }, .{     5,  1 }, .{     7,  1 },
    .{     9,  2 }, .{    13,  2 }, .{    17,  3 },
    .{    25,  3 }, .{    33,  4 }, .{    49,  4 },
    .{    65,  5 }, .{    97,  5 }, .{   129,  6 },
    .{   193,  6 }, .{   257,  7 }, .{   385,  7 },
    .{   513,  8 }, .{   769,  8 }, .{  1025,  9 },
    .{  1537,  9 }, .{  2049, 10 }, .{  3073, 10 },
    .{  4097, 11 }, .{  6145, 11 }, .{  8193, 12 },
    .{ 12289, 12 }, .{ 16385, 13 }, .{ 24577, 13 },
];

Table_Data :: struct {
    value: u16;
    extra_bits: u8;
}
