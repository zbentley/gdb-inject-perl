### TODO:

- Build system:
	- Doctoc for README(s).
	- Placeholders for project and script name.
- GDB test-run: dylib version errors, etc.
- Document debug requirement.
- Interpolation of longmess so as not to need Carp?
- Enable/disable C backtrace.
- Tests.
- Thread support.
- Execute code from commandline or from file.
- Look into Devel::GDB.
- Better OSX support (lldb?)

# Why is it written in Go, not Perl?

`gdb-inject-perl` was written in Perl eventually (and that version can still be used; it's in the `legacy-pure-perl` subdirectory of the source repository). So why the switch? A few reasons:

- Static Linking/Runtime Dependencies. Running the compiled Go version of `gdb-inject-perl` doesn't require Perl, Go, or any preinstalled software other than libc. If that seems pointless, consider the use case of debugging an embedded Perl interpreter (e.g. in `mod_perl` or similar) on a system that does not have a compatible or usable installation of the `perl` commandline utility. Systems without commandline Perls are admittedly rare, but also consider that some systems may not have Perl easily locatable on the `PATH`, and that different versions of Perl make different runtime assumptions and support different features, and that commandline-Perl may often be severely outdated, or custom-compiled for a system. While trying to get emergency debugging information from an embedded, opaque Perl process, having to stop and deal with the vagaries of operating system package configuration is far from ideal.
	- A commandline Perl interpreter is still required for testing custom `--code` values being injected. Testing can, however, be bypassed with the `--force` switch.
- Library Dependencies. The pure-Perl version had several CPAN modules as dependencies. For some users, installing CPAN modules in order to use a last-ditch debugging tool may take too much time, be out of the user's expertise level, or not be supported when running as the root user (which is required in order to use this script). Since Go is compiled and statically linked, it should be dependecy-free; even though third-party dependencies are used in the source code, end users don't have to remember to install them, provided they are running the version of `gdb-inject-perl` written for thier operating system.
- Concurrency. Even though `gdb-inject-perl` is very simple, it still needs low-level access to pipes, and needs to simultaneously wait for timeouts, user signals, or output from the process being inspected. This is totally possible in Perl, but, due to Perl's single-threaded nature and default buffering, requires careful coding around `sysread` and `select`, or the installation of additional CPAN dependencies. The implementation in the pure-Perl version of `gdb-inject-perl` is far from perfect, and is still nearly a hundred lines of relatively esoteric code. Go suports multiplexed event waiting by default, and also has more powerful standard-library facilities for dealing with pipes.
