// build.jai
// Builds the tests for the Gzip module
//

// This is just to add the parent directory to the modules path for the compiler
#run {
    options := get_build_options();
    cmdl := options.compile_time_command_line;

    is_release_mode := false;
    optimization_level: Optimization_Type = .DEBUG;
    for arg: cmdl {
        if arg == {
            case "release";
                is_release_mode = true;
                optimization_level = .OPTIMIZED;

            case "dist"; #through;
            case "distribution";
                is_release_mode = true;
                optimization_level = .VERY_OPTIMIZED;

            case;
                log_error("Unknown option '%'. Skipping.", arg);
        }
    }

    // Tell the compiler not to produce an executable for this workspace
    set_build_options_dc(.{ do_output = false });

    // Retarget working directory to the projects root
    set_working_directory(#filepath);

    // Include modules in the parent folder
    import_path: [..] string;
    array_add(*import_path, "../"); // we want to add the module that is in our parent directory
    array_add(*import_path, ..options.import_path);
    options.import_path = import_path;

    // Name the target executable
    options.output_executable_name = "test";

    // Setup optimizations
    set_optimization(*options, optimization_level);

    // Turn on arithmetic overflow warning!
    options.arithmetic_overflow_check = ifx is_release_mode then .NONFATAL else .FATAL; // I prefer my warnings as errors, but in release mode we can just leave them as warnings

    // Create the workspace which will build the actual executable
    workspace := compiler_create_workspace(options.output_executable_name);
    set_build_options(options, workspace);

    compiler_begin_intercept(workspace);
    add_build_file("test.jai", workspace);

    // Intercept compiler messages here
    //

    compiler_end_intercept(workspace);

    // Needed imports for the functions above
    #import "Basic";
    #import "Compiler";
}
