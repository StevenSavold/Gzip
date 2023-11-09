
main :: () {
    success, unzipped_content, header, footer := gunzip("input/CHANGELOG.txt.gz");
    if !success {
        log_error("ERROR: Unable to uncompress the file.");
        return;
    }

    file_content, success= := read_entire_file("input/CHANGELOG.txt");
    if !success {
        log_error("ERORR: unable to read raw file!");
        return;
    }

    if file_content.count != unzipped_content.count && memcmp(file_content.data, unzipped_content.data, unzipped_content.count) != 0 {
        log_error("ERROR: Files were not identical!");
        return;
    }
    free(file_content); // make sure to free our file we are using to check validity

    // The user needs to free these things manually in their program!
    array_free(unzipped_content);
    if header.name        then free(header.name);
    if header.comment     then free(header.comment);
    if header.extra_feild then free(header.extra_feild);

    options: Leak_Report_Options;
    report_memory_leaks(*options);
}

#import "Basic"()(MEMORY_DEBUGGER = true);
#import "File";

#import,file "../module.jai";
