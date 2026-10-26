## Build Plugin

The build plugin works on a set of *targets*, that are either specified by a combination of the project config and user config, or, if no targets are specified, inferred automatically from the installed build backends.

### Targets

Targets are the basis of the build plugin. Different build systems can co-exist simultaneously. By default, there are only three fields in a target:

* `name`: The identifier of the target.
* `binary`: The path to the primary executable.
* `backend`: Either the backend itself, or the name of a registered backend.
* `wd`: The working directory to run the `binary` in when executed.
* `run`: The command necessary to execute this target: a function of the target returning a command (see below), or a program. If blank, will execute `binary`.

### The build terminal

Builds, cleans and runs happen in a terminal in a drawer under the editor (f6 shows or hides it). Each command a backend runs gets a pty of its own in it, after the output of the commands before, so colors, progress lines and ctrl+c work as in a shell, and a program run reads the keyboard. A dim line shows each command; a line at the end says how the build went.

Lines in gcc's and clang's format, `file:line:column: type: message`, are found as they're written, with paths relative to the command's directory, or to the one make or ninja says it's entering. Clicking one opens its file there; f4 and shift+f4 go to the next and previous error or warning of the last build, and the status bar's build item shows how many there were (or that it failed).

### Backends

Backends **should** supply the following methods:

* `build(target, callback)`: Builds the specified target, then calls `callback(status)` with the exit status (0 for success).
* `clean(target, callback)`: Cleans the specified target, then calls `callback(status)`.

These run in a thread. A command runs with `build.run_command(cmd, on_done)`: `cmd` is a list, the program then its arguments, with optional `cwd` (default: the project's directory) and `env` (variables added); `on_done(status)` is called once it exits, and can run the next one. A backend's build usually ends with `build.run_command(cmd, callback)`.

Backends **can** supply the following methods:

* `infer()`: Called in a coroutine; returns the list of targets that this backend supports for this project.
* `priority`: The order in which `infer` is called, so build systems can act as fallbacks. Default 0, sorting ascending.
* `run(target, arguments)`: Returns the command (as for `build.run_command`) running the target; `build.get_run_command` makes one from a program and arguments.
* `parse_compile_line(line)`: Finds a message in a line of output (see `build.parse_compile_line`), for a format other than gcc's.

#### make

The `make` backend engages with `Makefile`s. If a `Makefile` exists, by default, the backend will infer the "all" target, which will simply call `make` with no arguments.

#### shell

The `shell` backend engages with a file called `build.sh`. If a `build.sh` file exists, by default the backend will infer a `debug` target, which will call the `build.sh` file with `-g`, and a `release` target, which will call the `build.sh` file with no arguments.

#### meson

The `meson` backend engages with a `meson.build` file. If a `meson.build` file exists, by default will infer a `debug` target, which if the directory `build-debug` doesn't exist will create it, and call `meson setup build-debug`. It will then call `ninja -C build-debug`.

#### vscode

The `vscode` backend reads VS Code's `.vscode/launch.json` and `.vscode/tasks.json` (comments and trailing commas allowed, with the `linux`/`osx`/`windows` overrides). Each launch configuration with `"request": "launch"` is a target: building runs its `preLaunchTask` (after the tasks in its `dependsOn`, in sequence), and running starts its `program` with its `args`, in its `cwd`, with its `environment` (or `env`). For the native debugger types (`cppdbg`, `gdb`, `lldb`), the debugger plugin debugs that program the same way, after the configuration's `setupCommands`; other types with a `command` (`node-terminal`) or a `program` are only run. Each task is a target too, build only: `shell` tasks run their command line with `$SHELL -c` (or `options.shell`), `process` and `cppbuild` tasks run their command directly, in `options.cwd` with `options.env`. Errors are found as gcc's (`$gcc`).

Variables: `${workspaceFolder}`, `${workspaceFolderBasename}`, `${file}`, `${relativeFile}`, `${fileBasename}`, `${fileBasenameNoExtension}`, `${fileDirname}`, `${fileExtname}`, `${lineNumber}`, `${selectedText}`, `${cwd}`, `${userHome}`, `${pathSeparator}` and `${env:NAME}`. Not supported: other variables, other problem matchers, background tasks, `presentation`, parallel `dependsOrder`, compound and attach configurations, `stopAtEntry`.

Targets are found again when either file is saved, and on changing project.

#### internal

If no other backend has engaged, internal will look for a `src` folder. If it finds it, it will automatically compile every `*.c` or `*.cpp` file in there with standard build parameters, writing a makefile for it under `obj` that `make` runs. 
You can specify also the following types of flags in the target:

* `cflags` - Compile flags to pass while compinling object files for \*.c files.
* `cxxflags` - Compile flags to pass while compiling object files for \*.cpp files.
* `ldflags` - Linking flags to pass while linking together your object files.
* `type` - The type of output to produce. Possible values are `static`, `shared` and `executable`. Default is `executable`.
* `binary` - The resulting target name for the binary.


### Example Config

When setting up a project, you had a makefile driven project, you could place the following in your project module to get 5 targets, 3 of which are executable:

```lua
config.plugins.build.targets = {
  { name = "TestSanity", binary = "bin/01sanity" },
	{ name = "LibraryDebug" },
	{ name = "LibraryRelease" },
	{ name = "WebserverDebug", binary = "bin/searchserver" },
	{ name = "WebserverRelease", binary = "bin/searchserver" }
}
config.plugins.build.type = "make"
```


