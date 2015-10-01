# Overview
### What does it do?

It uses [GDB](http://www.gnu.org/software/GDB/) to attach to a running Perl process, and injects in a perl "eval" call with a string of code supplied by the user (it defaults to code that prints out the Perl call stack). If everything goes as planned, the Perl process in question will run that code in the middle of whatever else it is doing.

### Usage

##### Prerequisites:

1. First, identify the PID of the Perl process that you want to debug. In the below examples, it's a backgrounded process created at the top.
2. Ensure you are running as a user with permissions to attach to the PID in question (either the user that owns the process or root, usually).

##### Dumping the call stack:


##### Running arbitrary code:


##### Safeguards:
There are a few basic safeguards used by gdb-inject-perl. 

- Code that will not compile with `strict` and `warnings` will be rejected. You can use the `--force` switch to run it anyway (at your own risk).
	- **Warning:** "Will it compile?" is checked using `perl -c`, which []will run BEGIN and END blocks](http://stackoverflow.com/a/12908487/249199). If your code has any, it's probably a bad idea. Also, they will be executed during the pre-injection compilation check.
- Code containing literal double quotation marks, even backslash-escaped ones, will be rejected. You can use the `--force` switch to run it anyway (at your own risk).
	- This restriction is imposed because code must be supplied as a string argument into a GDB call. You can work around it by using the [alternative quoting constructs in Perl](http://perldoc.perl.org/perlop.html#Quote-and-Quote-like-Operators), e.g. `$interpolated = qq{var: $var}; $not_interpolated = q{var: $var}`.
- If `gdb` cannot be found on your system, the script will not start.

### Where/when can I use it?

This program only works on POSIX-like OSes on which GDB is installed. In practice, this includes most Linuxes, BSDs, and Solaris OSes out of the box. GDB can be installed on [OSX](http://ntraft.com/installing-gdb-on-os-x-mavericks/) and other operating systems as well.

- It works on scripts.
- It works on mod_perl processes.
- It works on other CGI Perls inside webservers.
- It works on (many/most) embedded Perls.

Just pass it the process ID of a Perl process and it will do its best to inject code.

### Requirements

- POSIX-ish OS.
- Modern Perl (5.6 or later, theoretically; 5.8.8 or later in practice).
- GDB installed.
- CPAN modules:
	- `File::Which`
	- `Capture::Tiny`



### So what's the catch?
It's incredibly dangerous.

The script works by injecting arbitrary function calls into the runtime of a complex, high-level programming language (Perl). Even if the code you inject doesn't modify anything, it might be injected in the wrong place, and corrupt internal interpreter state. If it _does_ modify anything, the interpreter might not detect state changes correctly.

In short, it should not be used on a healthy process with important functionality that could be interrupted. "Interrupted", in this case, does not mean the same thing as a signal interrupt (Perl-safe or unsafe); it's possible to break/segfault/corrupt Perl in the midst of operations that would not normally be interruptible at all. gdb-inject-perl tries to mimic safe-signal delivery behavior, but does not do so erfectly.

### Where/when _should_ I use it?

gdb-inject-perl is recommended for use on processes that are already known to be deranged, and that are soon to be killed.

If a Perl process is stuck, broken, or otherwise malfunctioning, and you want more information than logs, `/proc`, `lsof`, `strace`, or any of the other standard [black-box debugging](http://jvns.ca/blog/2014/04/20/debug-your-programs-like-theyre-closed-source/) utilities can give you, you can use gdb-inject-perl to get more information.


# FAQ

### It doesn't work; it just says "Attaching to process". What gives?

Your process is probably in a blocking system call or uninterruptible state (doing something other than just running Perl code). Try `strace` and friends.

### On OSX it times out after saying "Unable to find Mach task port for process-id ___"

You need to [codesign the debugger](https://gcc.gnu.org/onlinedocs/gcc-4.8.0/gnat_ugn_unw/Codesigning-the-Debugger.html).


### I want to inject something that changes my running program's state. Can I?

Sure, but don't come crying to me when it segfaults your application.

### I want to inject code into multiple places inside a process. Can I?
- Probably, but if you do, don't tell me how you pulled it off. It sounds like you need a [real](https://metacpan.org/pod/Devel::Trepan) [debugger](http://search.cpan.org/~arc/perl/pod/perldebug.pod).

### Why not just use the Perl debugger/GDB directly?
- You might not need it. gdb-inject-perl is intended for a much, much simpler use case than the Perl debugger (or the excellent [trepan](https://metacpan.org/pod/Devel::Trepan)): getting a little bit of context information out of a process that you might not know anything about. As a result, **simplicity is paramount**: the person monitoring and/or killing a Perl process might not know how to use the Perl debugger; they might not be a developer at all.
- Debug symbols/Perl debugger support might not exist in your environment (certain embedded Perls, or bizarre system Perls). Even in those cases, the "caller" stack is usable for context information about a Perl process, and gdb-inject-perl can get it for you.

### Why use FIFOs, and not use perl debugger's RemotePort functionality?
Something else might be using it. gdb-inject-perl is meant to be usable with minimal interference with other code running in a Perl process, _even other debuggers_.

### See also:
- Zombie free linux
- Enbugger
- http://www.perlmonks.org/?node_id=694095
- https://docs.google.com/presentation/d/1Lxk_YHUEV3k4dXJZlpsgUuph0PwmvpHbI8EX8Igy5rY/edit#slide=id.g11c288d8_0_35
- https://gist.github.com/p120ph37/2bf794a86eeab0445658
- https://metacpan.org/pod/Devel::Trepan
- http://search.cpan.org/~arc/perl/pod/perldebug.pod