# Contents
<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Overview](#overview)
    - [Usage](#usage)
        - [Setup](#setup)
        - [Dumping the call stack](#dumping-the-call-stack)
        - [Running arbitrary code](#running-arbitrary-code)
        - [Safeguards and limitations](#safeguards-and-limitations)
        - [Options](#options)
    - [Where/when can I use it?](#wherewhen-can-i-use-it)
    - [So what's the catch?](#so-whats-the-catch)
    - [Where/when _should_ I use it?](#wherewhen-_should_-i-use-it)
- [System Requirements](#system-requirements)
- [FAQ](#faq)
    - [It doesn't work; it just says "Attaching to process". What gives?](#it-doesnt-work-it-just-says-attaching-to-process-what-gives)
    - [On OSX it times out after saying "Unable to find Mach task port for process-id ___"](#on-osx-it-times-out-after-saying-unable-to-find-mach-task-port-for-process-id-___)
    - [I want to inject something that changes my running program's state. Can I?](#i-want-to-inject-something-that-changes-my-running-programs-state-can-i)
    - [I want to inject code into multiple places inside a process. Can I?](#i-want-to-inject-code-into-multiple-places-inside-a-process-can-i)
    - [Why not just use the Perl debugger/GDB directly?](#why-not-just-use-the-perl-debuggergdb-directly)
    - [Why use FIFOs, and not use perl debugger's RemotePort functionality?](#why-use-fifos-and-not-use-perl-debuggers-remoteport-functionality)
- [Additional Resources](#additional-resources)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# Overview
gdb-inject-perl is a script that uses [GDB](http://www.gnu.org/software/GDB/) to attach to a running Perl process, and injects in a perl "eval" call with a string of code supplied by the user (it defaults to code that prints out the Perl call stack). If everything goes as planned, the Perl process in question will run that code in the middle of whatever else it is doing.

### Usage

##### Setup
1. First, identify the PID of the Perl process that you want to debug. In the below examples, it's a backgrounded process created at the top.
2. Ensure you are running as a user with permissions to attach to the PID in question (either the user that owns the process or root, usually).

##### Dumping the call stack

	# Run something in the background that has a particular call stack:
    perl -e 'sub Foo { my $s = shift; eval $s; } sub Bar { Foo(@_) }; eval { Bar("while (1) { sleep 1; }"); };' &

    inject.pl --pid $!
        DEBUG at (eval 1) line 1.
	    eval 'while (1) { sleep 1; }
	    ;' called at -e line 1
	    main::Foo(undef) called at -e line 1
	    main::Bar('while (1) { sleep 1; }') called at -e line 1
	    eval {...} called at -e line 1

##### Running arbitrary code

	# There's nothing stopping you from using the captive process's STD* streams:
    inject.pl --pid <SOMEPID> --code 'print STDERR qq{FOOO $$}; sleep 1;'
        FOOO <SOMEPID> # printed from other process
    
    # The special file handle $fh is provided to your injected code as a
    # way to communicate back to gdb-inject-perl:
    inject.pl --pid <SOMEPID> --code 'print $fh STDERR qq{FOOO $$}; sleep 1;'
        FOOO <SOMEPID> # printed from gdb-inject-perl

##### Safeguards and limitations
There are a few basic safeguards used by gdb-inject-perl. 

- Code that will not compile with `strict` and `warnings` will be rejected. You can use the `--force` switch to run it anyway (at your own risk).
	- **Warning:** "Will it compile?" is checked using `perl -c`, which [will run `BEGIN` and `END` blocks](http://stackoverflow.com/a/12908487/249199). Such blocks will be executed during the pre-injection compilation check.  Besides, if code you plan on injecting into an already-running Perl process has `BEGIN` or `END` blocks, it's probably a bad idea.
- Code containing literal double quotation marks, even backslash-escaped ones, will be rejected. You can use the `--force` switch to run it anyway (at your own risk).
	- This restriction is imposed because code must be supplied as a string argument into a GDB call. You can work around it by using the [alternative quoting constructs in Perl](http://perldoc.perl.org/perlop.html#Quote-and-Quote-like-Operators), e.g. `$interpolated = qq{var: $var}; $not_interpolated = q{var: $var}`.
- If `gdb` cannot be found on your system, the script will not start.

##### Options
* **--pid PID**
	* Process ID of the Perl process to inject code into. PID can be any kind of Perl process: embedded, mod_perl, simple script etc.
	* This option is required.
* **--code CODE**
	* String of code that will be injected into the Perl process at PID and run. This code will have access to a special file handle, $fh, which connects it to inject.pl. When $fh is written to, the output will be returned
               by inject.pl. If CODE is omitted, it defaults to printing the value of Carp::longmess to $fh.
	* CODE should not perform complex alterations or change the state of the program being attached to.
	* CODE may not contain double quotation marks or Perl code that does not compile with strict and warnings. To bypass these restrictions, use --force.
* **--verbose**
	* Show all GDB output in addition to values captured from the process at PID.
* **--force**
	* Bypass sanity checks and restrictions on the content of CODE.
* **--help**
	* Show help message.
* **--man**
	* Show manpage/perldoc.

### Where/when can I use it?
This program only works on POSIX-like OSes on which GDB is installed. In practice, this includes most Linuxes, BSDs, and Solaris OSes out of the box. GDB can be installed on [OSX](http://ntraft.com/installing-gdb-on-os-x-mavericks/) and other operating systems as well.

- It works on scripts.
- It works on mod_perl processes.
- It works on other CGI Perls inside webservers.
- It works on (many/most) embedded Perls.

Just pass it the process ID of a Perl process and it will do its best to inject code.

### So what's the catch?
It's incredibly dangerous.

The script works by injecting arbitrary function calls into the runtime of a complex, high-level programming language (Perl). Even if the code you inject doesn't modify anything, it might be injected in the wrong place, and corrupt internal interpreter state. If it _does_ modify anything, the interpreter might not detect state changes correctly.

In short, it should not be used on a healthy process with important functionality that could be interrupted. "Interrupted", in this case, does not mean the same thing as a signal interrupt (Perl-safe or unsafe); it's possible to break/segfault/corrupt Perl in the midst of operations that would not normally be interruptible at all. gdb-inject-perl tries to mimic safe-signal delivery behavior, but does not do so perfectly.

### Where/when _should_ I use it?
gdb-inject-perl is recommended for use on processes that are already known to be deranged, and that are soon to be killed.

If a Perl process is stuck, broken, or otherwise malfunctioning, and you want more information than logs, `/proc`, `lsof`, `strace`, or any of the other standard [black-box debugging](http://jvns.ca/blog/2014/04/20/debug-your-programs-like-theyre-closed-source/) utilities can give you, you can use gdb-inject-perl to get more information.

# System Requirements
- POSIX-ish OS.
- Modern Perl (5.6 or later, theoretically; 5.8.8 or later in practice).
- GDB installed.
- CPAN modules:
	- [`File::Which`](https://metacpan.org/pod/File::Which)
	- [`Capture::Tiny`](https://metacpan.org/release/Capture-Tiny)

# FAQ

### It doesn't work; it just says "Attaching to process". What gives?
Your process is probably in a blocking system call or uninterruptible state (doing something other than just running Perl code). Try `strace` and friends.

### On OSX it times out after saying "Unable to find Mach task port for process-id ___"
You need to [codesign the debugger](https://gcc.gnu.org/onlinedocs/gcc-4.8.0/gnat_ugn_unw/Codesigning-the-Debugger.html).

### I want to inject something that changes my running program's state. Can I?
Sure, but don't come crying to me when it segfaults your application.

### I want to inject code into multiple places inside a process. Can I?
Probably, but if you do, don't tell me how you pulled it off. It sounds like you need a [real](https://metacpan.org/pod/Devel::Trepan)[1] [debugger](http://search.cpan.org/~arc/perl/pod/perldebug.pod)[2].

### Why not just use the Perl debugger/GDB directly?
- You might not need it. gdb-inject-perl is intended for a much, much simpler use case than the [Perl debugger](http://search.cpan.org/~arc/perl/pod/perldebug.pod) (or the excellent [trepan](https://metacpan.org/pod/Devel::Trepan)): getting a little bit of context information out of a process that you might not know anything about.
	- **Simplicity is paramount**: the person monitoring and/or killing a Perl process might not know how to use the Perl debugger; they might not know what Perl is. Consider the example of a support technician or administrator that finds a process that is hung and breaking an important service: with gdb-inject-perl, they can run a command, send its output to the developers that maintain the service, and kill it as the normally would: no Perl understanding required.
- Debug symbols/Perl debugger support might not exist in your environment (certain embedded Perls, or bizarre system Perls). Even in those cases, the "caller" stack is usable for context information about a Perl process, and gdb-inject-perl can get it for you.

### Why use FIFOs, and not use perl debugger's RemotePort functionality?
Something else might be using it. gdb-inject-perl is meant to be usable with minimal interference with other code running in a Perl process, _even other debuggers_.

# Additional Resources
- Perlmonks [conversation about gdb-eval injection](http://www.perlmonks.org/?node_id=694095)
- Massive [presentation on various Perl debugging strategies, including this one](https://docs.google.com/presentation/d/1Lxk_YHUEV3k4dXJZlpsgUuph0PwmvpHbI8EX8Igy5rY/edit#slide=id.g11c288d8_0_35)
- [Script that does the same thing, but for threaded perl](https://gist.github.com/p120ph37/2bf794a86eeab0445658)
- [Devel::Trepan](https://metacpan.org/pod/Devel::Trepan)
- The [Perl debugger](http://search.cpan.org/~arc/perl/pod/perldebug.pod)
- [Enbugger](https://metacpan.org/pod/distribution/Enbugger/lib/Enbugger.pod)
- [Zombie free linux with GDB](http://www.mattfiddles.com/computers/linux/zombie-slayer) (terrifying)