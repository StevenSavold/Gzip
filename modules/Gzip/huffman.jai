
// The returned tree is heap allocated. unless a custom allocator is used, it will need to be freed.
//
// Also, if when building the tree, we encounter an error, the tree will be freed and will require the
// allocator be able to at least ignore the requests to free the nodes
//
create_huffman_tree :: (code_lengths: [] u8, max_huffman_code_length: u8 = 15) -> success: bool, tree: *Huffman_Node {
    if code_lengths.count > 288 {
        log_error("GZIP   [ERROR]: unable to build huffman tree, expected code_lengths.count to be less then 288");
        return false, null;
    }

    success, codes := create_huffman_codes(code_lengths, max_huffman_code_length);
    if !success then return false, null;
    defer { array_free(codes); }; // Since codes is allocated on the heap, we need to free it. But only if it was valid (success == true)

    root := New(Huffman_Node);

    for codes {
        current_node := root;

        for j: 0..it.length-1 { // -1 because jai for loops are inclusive
            bit: u16 = (it.code >> cast(u16)(it.length - j - 1)) & 1; // Get the bits from left to right (most signifigant to least signifigant)
            child: **Huffman_Node = ifx bit then *current_node.right else *current_node.left; // Grab a reference to the child we will want to operate on

            // The formatting of this if statment is ugly, but I think it will help to allow the comments to explain what this is checking for...
            if  ((j == it.length - 1) && (<<child != null)) || // If we are on the last bit and there is already a node here... We have doubled up and the tree is invalid
                ((j != it.length - 1) && (<<child != null) && ((<<child).code != -1) ) // If we have hit a terminating (leaf) node in the tree, we have a substring in our patten that is ambiguaous and the tree is invalid
            {
                destroy_huffman_tree(root);
                return false, null;
            }

            if <<child == null then
                <<child = New(Huffman_Node);

            if j == it.length - 1 then
                (<<child).code = xx it_index;

            current_node = <<child; // Move our current_node reference down the tree
        }
    }

    return true, root;
}

destroy_huffman_tree :: (node: *Huffman_Node) {
    if node == null then return;

    // Smash that stack!
    if node.right {
        destroy_huffman_tree(node.right);
    }
    if node.left {
        destroy_huffman_tree(node.left);
    }

    free(node);
}

// This function should return a u8 that is either 1 or 0, nothing else. This allows the user
// to be able to read their bits however they want and the tree finding function need not care
// how it works
Next_Bit_Func :: #type (user_data: *void) -> (bit: u8, success: bool);
find_huffman_code :: (tree: *Huffman_Node, next_bit_func: Next_Bit_Func, user_data: *void) -> *Huffman_Node {
    if tree == null {
        log_error("GZIP   [ERROR]: unable to find code in huffman tree, tree pointer was null");
        return null;
    }

    current := tree;
    while current.code == -1 {
        // grab the next bit, in however the user wants to do so
        bit, success := next_bit_func(user_data);
        if !success then return null; // We dont need to log an error because its the users code that faulted. They can print if they errored

        // Choose a child based on the bit
        current = ifx bit then current.right else current.left;
        if current == null {
            log_error("GZIP   [ERROR]: unable to find code in huffman tree, encounterd a null node when trying to find huffman code");
            return null;
        }
    }

    return current;
}

// This algorithm comes from the DEFLATE specification: (https://www.ietf.org/rfc/rfc1951.txt [3.2.2])
create_huffman_codes :: (code_lengths: [] u8, max_huffman_code_length: u8 = 15) -> success: bool, codes: [] Huffman_Code {
    if code_lengths.count > 288 {
        log_error("GZIP   [ERROR]: unable to create huffman codes, expected code_lengths.count to be less then 288");
        return false, .[];
    }

    if max_huffman_code_length > 15 then log("GZIP [WARNING]: 'max_huffman_code_length' was set higher then 15. Defaulting to 15 instead."); // It should be okay to warn here, because if more then 15 lengths were provided, we will error in step [1]
    max_huffman_code_length = min(max_huffman_code_length, 15);

    // [1] Count the number of codes for each code length...
    code_length_counts: [16] u16;
    for code_lengths {
        if it > max_huffman_code_length {
            log_error("GZIP   [ERROR]: unable to create huffman codes, a supplied length was greater then the maximium allowed (length: %, max: %)", it, max_huffman_code_length);
            return false, .[]; // Because we would be indexing past the end of the code_lengt_counts array
        } 
        code_length_counts[it] += 1;
    }

    // [2] Find the numerical value of the smallest code for each code length
    next_code_for_length: [16] u16;
    code: u16 = 0;
    code_length_counts[0] = 0; // Do this because when bits==1 we will be accessing this part of the array. And we dont really care about how many lengths were 0, and dont want it to effect this calculation
    for bits: 1..15 {
        code = (code + code_length_counts[bits - 1]) << 1; // 'code' feeds back into itself each iteration
        next_code_for_length[bits] = code;
    }

    // [3] Assign numerical values to all codes, using consecutive values for all codes of the same length
    // with the base values determined at step 2. Codes that are never used (which have a bit length of
    // zero) must not be assigned a value.
    output_codes := NewArray(code_lengths.count, Huffman_Code);
    for *output_codes { // code_lengths and output_codes are parallel arrays
        it.length = code_lengths[it_index];
        if it.length == 0 continue; // We dont need to care about codes with length 0, and the "code" part of the output will have already been set to 0 for us (because Jai clears memory by default)

        it.code = next_code_for_length[it.length];
        next_code_for_length[it.length] += 1;
    }

    return true, output_codes;
}

Huffman_Code :: struct {
    length: u8;
    code:   u16;
}

// Just a simple binary tree
Huffman_Node :: struct {
    code: s16 = -1;

    left:  *Huffman_Node;
    right: *Huffman_Node;
}



#scope_file

// Used when debugging, but probably not useful for a user
print_tree :: (node: *Huffman_Node, depth := 0) {
    // Print the depth offset
    for 1..depth {
        print("    ");
    }

    // base case
    if node == null {
        print("{ null }\n");
        return;
    }

    // print the node and its children
    print("{ code: % }\n", formatInt(node.code, base=10));
    print_tree(node.left, depth + 1);
    print_tree(node.right, depth + 1);
}

#import "Basic";
