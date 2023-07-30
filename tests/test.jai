// test.jai
//
// This file exists to test the Gzip module.
// TODO: Write a better description!
//

// This file is build by the 'build.jai' file at the top level of this repository
// to build simply navigate to the top level of this repo in a terminal and use
// the command:
//
//      jai build.jai
//

// TODO: remove me?
// #run main();


main :: () {

    // TODO: Make test harness that will loop over all files in the tests/input directory
    //       and compare the inflated content to the corresponding data in tests/output
    //
    //       also use this link: https://github.com/nayuki/Simple-DEFLATE-decompressor/blob/master/java/test/DecompressorTest.java
    //       to construct some "in-memory" tests without needing to load the files
    //

    success :: true;  // used when a test is expected to pass
    failure :: false; // used when a test is expected to fail

    push_allocator(temp); // use the temporary allocator, the test functions will reset it after every test completion
    context.print_style.default_format_int.base = 16;

    // Test the uninteresting bits to make sure they work
    assert(test_gunzip(success, uninteresting_gzip_header(), uninteresting_deflate_payload()), "[gzip] basic uninteresting uncompressed data");
    assert(test_unzip (success, uninteresting_zlib_header(), uninteresting_deflate_payload()), "[zlib] basic uninteresting uncompressed data");

    // Test the header format parsers
    // TODO: Add tests for header formats


    // Test the Deflate decompressor
    // Test to make sure we fail at the right times before we can decode our first block
    assert(test_gunzip(failure, .[], .[]), "[gzip] no data passed (should fail)");
    assert(test_gunzip(failure, uninteresting_gzip_header(), .[ 0b0000_0111 ]), "[gzip] reserved block type (should fail)");
    assert(test_gunzip(failure, uninteresting_gzip_header(), .[]), "[gzip] valid header, but no payload (should fail)");
    assert(test_gunzip(failure, uninteresting_gzip_header(), .[ 0b0000_0001, 0x00 ]), "[gzip] valid header, but eof before end of payload (should fail)");

    // Test the uncompressed block parser
    assert(test_gunzip(success, uninteresting_gzip_header(), make_uncompressed_payload("hello", true), "hello"), "[gzip] uncompressed payload");
    assert(test_gunzip(success, uninteresting_gzip_header(), combine_two_payloads(make_uncompressed_payload("hello ", false), make_uncompressed_payload("sailor", true)), "hello sailor"), "[gzip] uncompressed two block payload");
    assert(test_gunzip(failure, uninteresting_gzip_header(), make_uncompressed_payload("hello", false)), "[gzip] end of file before getting final block (should fail)");

    // Test the fixed decompressor
    assert(test_gunzip(success, uninteresting_gzip_header(), .[ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 ], "hello"), "[gzip] fixed huffman payload");

    // Test the dynamic decompressor
    // TODO: Add tests for the dynamic block decompressor


    // done!
    log("All tests passed :)");
}

// Generates the bytes for a standard and uninteresting gzip
// header. So that we can worry about testing the deflate payload
uninteresting_gzip_header :: () -> [] u8 {
    //        magic         CM      Flags   Timestamp                 extra flags   OS id
    return .[ 0x1f, 0x8B,   0x08,   0x00,   0x00, 0x00, 0x00, 0x00,   0x00,         0x00, ];
}

uninteresting_zlib_header :: () -> [] u8 {
    // TODO: Add a byte breakdown to know what each bit means like we have in the uninteresting_gzip_header function
    return .[ 0x78, 0x9C, ];
}

// Generates the bytes for a standard and uninteresting deflate
// payload. So that we can worry about testing the headers
uninteresting_deflate_payload :: () -> [] u8 {
    return .[
        0b0000_0001, // a final block that uses no compression, and then padded 0's to move to the next byte

        0b0000_0000, // First byte of the LEN
        0b0000_0000, // Second byte of the LEN (LEN == 0)

        0b1111_1111, // First byte of NLEN
        0b1111_1111, // Second byte of NLEN (NLEN == ~LEN)

        // No more payload because LEN was 0
    ];
}

make_uncompressed_payload :: (payload: string, is_final: bool) -> [] u8 {
    header: u8  = cast(u8)is_final; // is a final block, and has type (00) "uncompressed"
    len:    u16 = xx payload.count;
    nlen:   u16 = ~len;

    output := NewArray(len + 5, u8); // +5 for the header/len/nlen bytes
    <<output.data = header;
    <<(cast(*u16)(output.data + 1)) = len;
    <<(cast(*u16)(output.data + 3)) = nlen;

    memcpy(output.data + 5, payload.data, payload.count);
    return output;
}

// Combines two arrays of bytes into one so it can be fed to unzip()
combine_two_payloads :: (first: [] u8, second: [] u8) -> [] u8 {
    new_length := first.count + second.count + 8; // +8 bytes for footer // TODO: This footer is wrong for zlib, we should changes this to test different footers
    new_array  := NewArray(new_length, u8);

    memcpy(new_array.data, first.data, first.count);
    memcpy(new_array.data + first.count, second.data, second.count);

    return new_array;
}

test_gunzip :: (expected_to_pass: bool, header: [] u8, payload: [] u8, expected_inflated_payload: string = "") -> bool {
    defer { reset_temporary_storage(); }; // Reset the temp allocator when we are done with this test

    // Make the test payload
    test_payload := combine_two_payloads(header, payload);

    // Test the payload
    success, content, header, footer := GZ.gunzip(test_payload);
    if success != expected_to_pass then return false; // Did it pass?

    if expected_to_pass { // If we do expect to pass, the content better match the expected uncompressed version
        if content.count != expected_inflated_payload.count then return false;
        diff := memcmp(content.data, expected_inflated_payload.data, content.count);
        return diff == 0;
    }

    return true; // We didnt expect to pass, and we did fail correctly
}

test_unzip :: (expected_to_pass: bool, header: [] u8, payload: [] u8, expected_inflated_payload: string = "") -> bool {
    defer { reset_temporary_storage(); }; // Reset the temp allocator when we are done with this test

    // Make the test payload
    test_payload := combine_two_payloads(header, payload);

    // Test the payload
    success, content, header := GZ.unzip(test_payload);
    if success != expected_to_pass then return false; // Did it pass?

    if expected_to_pass { // If we do expect to pass, the content better match the expected uncompressed version
        if content.count != expected_inflated_payload.count then return false;
        diff := memcmp(content.data, expected_inflated_payload.data, content.count);
        return diff == 0;
    }

    return true; // We didnt expect to pass, and we did fail correctly
}

#import "Basic";
GZ :: #import,file "../module.jai";
