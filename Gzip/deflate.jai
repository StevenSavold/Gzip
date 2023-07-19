


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

    new_state := <<state;
    new_state.byte += 2;  // Lets pretend we are at the end of the len, are we out of bounds?
    if !position_bounds_check(*new_state) return false;
    len: u16 = (cast(u16)state.input_buffer[state.byte]) + ((cast(u16)state.input_buffer[state.byte + 1]) << 8);
    state.byte += 2; // Now we move forward since we read it

    new_state.byte += 2;  // Lets pretend we are at the end of the len, are we out of bounds?
    if !position_bounds_check(*new_state) return false;
    nlen: u16 = (cast(u16)state.input_buffer[state.byte]) + ((cast(u16)state.input_buffer[state.byte + 1]) << 8);
    state.byte += 2; // Now we move forward since we read it

    if len != ~nlen {
        log_error("GZIP   [ERROR]: invalid block data, length did not match nlength");
        return false;
    }

    new_state.byte += len; // Lets pretend we are at the end of the block, are we out of bounds?
    if !position_bounds_check(*new_state) return false;

    for i: 0..(cast(s16)len)-1 { // -1 because jai arrays are inclusive
        array_add(output_buffer, state.input_buffer[state.byte + i]);
    }
    state.byte += len; // Now that we have read the bytes, move forward in the buffer

    return true;
}

parse_block_fixed :: (state: *Parse_State, output_buffer: *[..] u8) -> success: bool {
    lengths :: #run create_static_lengths_array();
    success, root := create_huffman_tree(lengths, 15); // We could do this at compile time if we didnt allocate the tree on the heap. It certainly would save needing to make the tree for each FIXED block. but how often are those used and will it really save all that much?
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
        }
        else if is_length_code(code) {
            success, length := get_length_from_code(code, state);
            if !success then return false;

            // the next 5 bits should be the distance code
            success=, distance_code := accumulate_bits(5, state);
            distance_code = invert_bits(distance_code, 5); // TODO: This seems to be correct, but is it? and if it is, why is reading the other things without this correct?

            if !success then return false;

            if !is_distance_code(xx distance_code) {
                log_error("GZIP   [ERROR]: invalid block data, found invalid distance code (%)", distance_code);
                return false;
            }

            success=, distance := get_distance_from_code(distance_code, state);
            if !success then return false;

            success = copy_bytes_from_distance(output_buffer, length, distance);
            if !success then return false;
        }
    }

    return true;
}

parse_block_dynamic :: (state: *Parse_State, output_buffer: *[..] u8) -> bool {
    // Get the HLIT (the number of litteral/length codes minus 257)
    success, hlit := accumulate_bits(5, state);
    if !success then return false;
    hlit += 257; // Add back that 257 to the decoded value

    if hlit < 257 || hlit > 286 {
        log_error("GZIP   [ERROR]: unexpected value in dynamic block, HLIT was expected to be in the range [257-287) (HLIT: %)", hlit);
        return false;
    }

    // Get the HDIST (the number of distance codes minus 1)
    success=, hdist := accumulate_bits(5, state);
    if !success then return false;
    hdist += 1; // Add back that 1 to the decoded value

    if hdist < 1 || hdist > 32 {
        log_error("GZIP   [ERROR]: unexpected value in dynamic block, HDIST was expected to be in the range [1-33) (HDIST: %)", hdist);
        return false;
    }

    // Get the HCLEN (the number of code lengths minus 4)
    success=, hclen := accumulate_bits(4, state);
    if !success then return false;
    hclen += 4; // Add back that 4 to the decoded value

    if hclen < 4 || hclen > 19 {
        log_error("GZIP   [ERROR]: unexpected value in dynamic block, HCLEN was expected to be in the range [4-20) (HCLEN: %)", hclen);
        return false;
    }

    // The code lengths are stored in a perticular order, as stated in https://www.rfc-editor.org/rfc/rfc1951.txt section 3.2.7
    code_length_order: [19] u8 : .[ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 ];
    code_lengths_for_the_code_length_alphabet: [19] u8; // 19 is the max, but we will only use HCLEN out of the 19 slots

    for i: 0..hclen-1 { // -1 because jai for loops are inclusive
        success=, length := accumulate_bits(3, state);
        if !success then return false;

        code_lengths_for_the_code_length_alphabet[code_length_order[i]] = cast(u8)length;
    }

    success=, root := create_huffman_tree(code_lengths_for_the_code_length_alphabet, 7);
    if !success then return false;

    // The repeat codes can use the data from the code lengths even in the distance codes section.
    // This means that there is effectivly one block of compressed code data (containing both length
    // and distance codes). The length of this block then, is our ajusted HLIT (HLIT + 257) plus our
    // adjusted HDIST (HDIST + 1) values. Each value being a variable length based on the huffman code
    // used. In other words, we need to loop HLIT + HDIST (using our adjusted values) times to have
    // gotten all the codes.
    // ref: https://www.rfc-editor.org/rfc/rfc1951.txt section 3.2.7 (at the bottom just before the "compliance" section)

    // This will be the array holding the whole block of data described above. Meaning
    // it will be a single array, the front section holding the code lengths for the
    // litterals, and the back section holding the code lengths for the distances.
    combined_code_lengths := NewArray(hlit + hdist, u8);
    i := 0;
    total := (hlit + hdist);

    while i < total {
        leaf := find_huffman_code(root, (user_data: *void) -> bit: u8, success: bool {
            bit, success := get(xx user_data);
            return bit, success;
        }, state);
        if leaf == null then return false;

        code := leaf.code;
        if !is_code_length_code(code) {
            log_error("GZIP   [ERROR]: invalid block data, found an invalid code length code in block (code: %)", code);
            return false;
        }

        // This is just to catch the edge case that we see a repeat code before we have seen any data to repeat
        if i == 0 && code == 16 {
            log_error("GZIP   [ERROR]: invalid block data, found repeat code without having seen any other codes previously");
            return false;
        }

        if code >= 0 && code <= 15 {
            // This is a litteral code, we can just plop the value into our buffer
            combined_code_lengths[i] = xx code;
            i += 1; // we added a code, so increment our index
        }
        else if code == 16 {
            // This is the repeat code, we need to read some bits and then repeat
            //  the last code we saw that number of times
            success=, repeat_count := accumulate_bits(2, state);
            if !success then return false;
            repeat_count += 3; // The repeat count is stored as repeat_count minus 3, so we need to add that back in

            for 0..repeat_count-1 { // -1 because jai for loops are inclusive
                if i >= total {
                    log_error("GZIP   [ERROR]: invalid block data, repeat code would cause too many codes");
                    return false;
                }
                combined_code_lengths[i] = combined_code_lengths[i - 1];
                i += 1; // we added a code, so increment our index
            }
        }
        else if code == 17 || code == 18 {
            // code 17 tells us to copy 0's 3-10 times
            // code 18 tells us to copy 0's 11-138 times
            extra_bits: u8 = ifx code == 17 then cast(u8)3 else cast(u8)7;
            offset: u8 = ifx code == 17 then cast(u8)3 else cast(u8)11;
            success=, repeat_count := accumulate_bits(extra_bits, state);
            if !success then return false;
            repeat_count += offset; // The repeat count is stored with an offset, make sure to add that back in

            for 0..repeat_count-1 { // -1 because jai for loops are inclusive
                if i >= total {
                    log_error("GZIP   [ERROR]: invalid block data, repeat code would cause too many codes");
                    return false;
                }
                combined_code_lengths[i] = 0;
                i += 1; // we added a code, so increment our index
            }
        }
    }

    // now we can split the arrays up to work on them separately
    litteral_code_lengths := array_view(combined_code_lengths, 0, hlit);
    distance_code_lengths := array_view(combined_code_lengths, hlit, hdist);

    destroy_huffman_tree(root); // We no longer need that tree data
    root = null; // We should not be using root below this point

    success=, litteral_lengths_root := create_huffman_tree(litteral_code_lengths, 15);
    if !success then return false;

    success=, distance_lengths_root := create_huffman_tree(distance_code_lengths, 15);
    if !success then return false;

    // All of the above, was just to get us the data to be able to decode the real data.
    // We start decoding the real data below this point...

    while true {
        leaf := find_huffman_code(litteral_lengths_root, (user_data: *void) -> bit: u8, success: bool {
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
        }
        else if is_length_code(code) {
            success, length := get_length_from_code(code, state);
            if !success then return false;

            // the next 5 bits should be the distance code
            distance_code_leaf := find_huffman_code(distance_lengths_root, (user_data: *void) -> bit: u8, success: bool {
                bit, success := get(xx user_data);
                return bit, success;
            }, state);
            if distance_code_leaf == null then return false;

            distance_code := distance_code_leaf.code;

            if !is_distance_code(distance_code) {
                log_error("GZIP   [ERROR]: invalid block data, found invalid distance code (%)", distance_code);
                return false;
            }

            success=, distance := get_distance_from_code(xx distance_code, state);
            if !success then return false;

            success = copy_bytes_from_distance(output_buffer, length, distance);
            if !success then return false;
        }
    }

    destroy_huffman_tree(litteral_lengths_root); // We no longer need the tree data
    destroy_huffman_tree(distance_lengths_root); // We no longer need the tree data

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

is_code_length_code :: (value: s16) -> bool {
    return value >= 0 && value <= 18;
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
