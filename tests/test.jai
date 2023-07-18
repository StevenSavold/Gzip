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

main :: () {

    // TODO: Make test harness that will loop over all files in the tests/input directory
    //       and compare the inflated content to the corresponding data in tests/output
    //
    //       also use this link: https://github.com/nayuki/Simple-DEFLATE-decompressor/blob/master/java/test/DecompressorTest.java
    //       to construct some "in-memory" tests without needing to load the files
    //

    success, content, header, footer := unzip("tests/input/example.jai.gz");
    if !success {
        log_error("Failed.");
        return;
    }

    log("header: %", header);
    log("content: '%'", to_string(content));
    log("footer: %", footer);

}

#import "Basic";
#import "Gzip";
