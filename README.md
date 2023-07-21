# Gzip (Jai)
This is a module for the Jai programming language. It implements a gzip decompressor with a compressor in the works.

# How to use
To use this library simply `git clone` or `git submodule add` to you projects modules folder (wherever that may be) and start `#import`ing it in your codebase.

The module currently has two main API functions:
```Jai
unzip :: (content: [] u8) -> (success: bool, unziped_content: [] u8, header: Header, footer: Footer) 
```
```Jai
unzip :: (filename: string) -> (success: bool, unziped_content: [] u8, header: Header, footer: Footer) 
```

The module API may change in the future, as I have plans to add flags to be able to check the validity of the CRC in the footer fo the file, as well as quiet the error logs for those who don't care about why the decoding might have failed. (or at least don't want it release builds?)

There are also plans to add the compressing side to this as well.

## Build the tests
In the projects tests folder, run the following command:
```shell
jai build.jai
```

The will produce a executable called `gzip-jai-module-tests.exe` and you can run that to verify the test cases pass.
