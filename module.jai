
// This module has the ability to uncompress gzip and zlib compressed data. It provides the following functions:
//     gunzip(content: [] u8): This function takes the bytes of content which are compressed using gzip and converts them to the uncompresed bytes
//     unzip(content: [] u8):  This function is the same as gunzip except the compression is expected to be zlib compression
//
// The module also provides two convienence functions:
//     gunzip(filename: string): This function will read the entire content of the provided filename and use those bytes to pass to the original gunzip function
//     unzip(filename: string): The same as the above function, but the file contents that are read are then passed to the original unzip
//

// TODO: Do we really need to return the header information to the user? I guess it could be helpful in gzip's case since there is some name and comment info in there...
// TODO: We probably dont need to return footer information as long as we provide a way to check that the crc and filesize are correct.
// TODO: Should we define a function that will try to be smart about what the content is and dynamically choose the unzip method? (gzip, zlib) Im not sure this is a good idea. its probably best to allow the user to check in whatever way is convinient for them

gunzip :: (content: [] u8) -> (success: bool, unziped_content: [] u8, header: Gzip_Header, footer: Gzip_Footer) {
    success, header, bytes_read := parse_gzip_header(content);
    if !success {
        return false, .[], .{}, .{};
    }

    body := array_view(content, bytes_read);
    success=, inflated_content := inflate(body);
    if !success return false, .[], .{}, .{};

    success=, footer := parse_gzip_footer(content);

    return success, inflated_content, header, footer;
}

unzip :: (content: [] u8) -> (success: bool, unzipped_content: [] u8, header: Zlib_Header) {
    success, header, bytes_read := parse_zlib_header(content);
    if !success {
        return false, .[], .{};
    }

    body := array_view(content, bytes_read);
    success=, inflated_content := inflate(body);
    if !success then return false, .[], .{};

    // TODO: parse zlib footer

    return success, inflated_content, header;
}









gunzip :: (filename: string) -> (success: bool, unzipped_content: [] u8, header: Gzip_Header, footer: Gzip_Footer) {
    content, success := read_entire_file(filename, false, true);
    if !success {
        log_error("GZIP      [ERROR]: unable to read file '%'", filename);
        return false, .[], .{}, .{};
    }

    defer free(content.data); // Make sure to realease the file content once we are done decompressing
    view: [] u8;
    view.data  = content.data;
    view.count = content.count;

    success=, unzipped_content, header, footer := gunzip(view);
    return success, unzipped_content, header, footer;
}


unzip :: (filename: string) -> (success: bool, unzipped_content: [] u8, header: Zlib_Header) {
    content, success := read_entire_file(filename, false, true);
    if !success {
        log_error("ZLIB      [ERROR]: unable to read file '%'", filename);
        return false, .[], .{};
    }

    defer free(content.data); // Make sure to realease the file content once we are done decompressing
    view: [] u8;
    view.data  = content.data;
    view.count = content.count;

    success=, unzipped_content, header := unzip(view);
    return success, unzipped_content, header;
}




#scope_file
#load "gzip.jai";
#load "zlib.jai";
#load "deflate.jai";

#import "Basic";
#import "File";
