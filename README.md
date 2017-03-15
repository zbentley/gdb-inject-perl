# Contents
<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Overview](#overview)
    - [Usage](#usage)
      - [Setup](#setup)
      - [Dumping the call stack](#dumping-the-call-stack)
      - [Running arbitrary code](#running-arbitrary-code)
      - [Options](#options)
    - [Where/when can I use it?](#wherewhen-can-i-use-it)
    - [So what's the catch?](#so-whats-the-catch)
    - [Where/when _should_ I use it?](#wherewhen-_should_-i-use-it)
- [System Requirements](#system-requirements)
- [Safeguards and Limitations](#safeguards-and-limitations)
- [Signals](#signals)
- [FAQ](#faq)
      - [It doesn't work; it just says "GDB process timed out". What gives?](#it-doesnt-work-it-just-says-gdb-process-timed-out-what-gives)
      - [After I used `gdb-inject-perl` on my process, it segfaulted/terminated/did something totally wrong! Why?](#after-i-used-gdb-inject-perl-on-my-process-it-segfaultedterminateddid-something-totally-wrong-why)
      - [On OSX it times out after saying "Unable to find Mach task port for process-id ___"](#on-osx-it-times-out-after-saying-unable-to-find-mach-task-port-for-process-id-___)
      - [I want to inject something that changes my running program's state. Can I?](#i-want-to-inject-something-that-changes-my-running-programs-state-can-i)
      - [I want to inject code into multiple places inside a process. Can I?](#i-want-to-inject-code-into-multiple-places-inside-a-process-can-i)
      - [Why not just use the Perl debugger/GDB directly?](#why-not-just-use-the-perl-debuggergdb-directly)
      - [Why use FIFOs, and not use perl debugger's RemotePort functionality?](#why-use-fifos-and-not-use-perl-debuggers-remoteport-functionality)
      - [Why is it written in Go, not Perl?](#why-is-it-written-in-go-not-perl)
- [Additional Resources](#additional-resources)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# Overview
*gdb-inject-perl* is a script that uses [GDB](http://www.gnu.org/software/GDB/) to attach to a running Perl process, and execute code _inside that process_. It works by using the debugger to inject a Perl `eval` call with a string of code supplied by the user (it defaults to code that prints out the Perl call stack). If everything goes as planned, the Perl process in question will run that code in the middle of whatever else it is doing.

### Usage

#### Setup
1. First, identify the PID of the Perl process that you want to debug. In the below examples, it's a backgrounded process created at the top.
2. Ensure you are running as a user with permissions to attach to the PID in question (either the user that owns the process or root, usually).

#### Dumping the call stack

```bash
    # Run something in the background that has a particular call stack:
    ~> perl -e 'sub Foo {
        my $stuff = shift; eval $stuff;
    }

    sub Bar {
        Foo(@_);
    };

    eval {
        Bar("while (1) { sleep 1; }");
    };' &
    [1] 1234
    
    # Inject code into the backgrounded process
    ~> gdb-inject-perl --pid 1234 # Print the call stack that the current PID is in the middle of:
    INJECT at (eval 1) line 1.
    eval 'while (1) { sleep 1; }
    ;' called at -e line 1
    main::Foo(undef) called at -e line 1
    main::Bar('while (1) { sleep 1; }') called at -e line 1
    eval {...} called at -e line 1
```
#### Running arbitrary code

```bash
    ~> gdb-inject-perl --pid 1234 --code 'print STDERR qq{FOOO $$}; sleep 1;'
    FOOO 1234 # printed from other process, wherever it's running, to its STDOUT

    ~> gdb-inject-perl --pid 1234 --code "print $fh qq{FOOO $$}; sleep 1;"
    FOOO 1234 # printed from gdb-inject-perl
```

#### Options

- `--pid PID`
	- Process ID of the Perl process to inject code into. `PID` can be any kind of Perl process: embedded, mod_perl, simple script, etc.
	- This option is required.
- `--code CODE`: String of code that will be injected into the Perl process at `PID` and run.
    - Defaults to returning the value of [Carp::longmess](https://metacpan.org/pod/Carp) back to `gdb-inject-perl`, with a carp string of `INJECT`. `Carp` will be required if not already present in the captive process.
    - Code that runs via `CODE` will have access to a special file handle in a local variable, `$fh`, which connects it to `gdb-inject-perl`. When `$fh` is written to, the output will be consumed and printed by `gdb-inject-perl`. 
    - `CODE` should not perform complex alterations or change the state of the program being attached to; if it does, the captive process may experience undefined behavior, or may just crash (it will often crash even if `CODE` is well-behaved; `gdb-inject-perl` is a last resort, after all).
    - `CODE` may not contain double quotation marks or Perl code that does not compile with [strict](hhttps://metacpan.org/pod/strict) and [warnings](https://metacpan.org/pod/warnings). To bypass these restrictions, use `--force`. This restriction is imposed because code must be supplied as a string argument into a GDB call. You can work around it by using the [alternative quoting constructs in Perl](http://perldoc.perl.org/perlop.html#Quote-and-Quote-like-Operators), e.g. `$interpolated = qq{var: $var}; $not_interpolated = q{var: $var}`.
- `--force`
	- If set, bypass sanity checks and restrictions on the content of `CODE`.
	- `--force` can also be used to bypass syntax-validation failures due to there not being a locatable `perl` binary on your system (e.g. if the target process is running an embedded Perl, or is using an interpreter at a nonstandard location).
	- Defaults to disabled.
- `--signals`
	- Enable the option to send signals to the process at `PID` if it does not generate debug output within the time specified by `TIMEOUT`. Once `gdb-inject-perl` has injected code into the process at `PID`, the user will be prompted to send signals to `PID` in order to interrupt any blocking system calls and force `CODE` to be run. See ["Signals"](#Signals) for more info.
	- Defaults to disabled.
- `--timeout TIMEOUT`
	- Time to wait until `PID` runs `CODE`. Accepts any string accepted by [ParseDuration](https://golang.org/pkg/time/#ParseDuration) (e.g. `10s`, `2.5m` etc.). If the timeout is exceeded (usually because `PID` is in the middle of a blocking system call), `gdb-inject-perl` gives up.
	- Defaults to `5s`.
- `--debug`
	- Show debug/raw GDB output in addition to values captured from the process at `PID`.
- `--help`
	- Show help message.

### Where/when can I use it?
This program only works on POSIX-like OSes on which GDB is installed. In practice, this includes most Linuxes, BSDs, and Solaris OSes out of the box. GDB [can be installed on OSX](http://ntraft.com/installing-gdb-on-os-x-mavericks/) (though it has problems with the dylib version installed on newer OSXes) and other operating systems as well.

- It works on scripts.
- It works on mod_perl processes.
- It works on other CGI Perls inside webservers.
- It works on (many/most) embedded Perls.

Just pass it the process ID of a Perl process and it will do its best to inject code.

### So what's the catch?
It's incredibly dangerous. Only use it on processes that you're OK with having killed.

The script works by injecting arbitrary function calls into the runtime of a complex, high-level programming language (Perl). Even if the code you inject doesn't modify anything, it might be injected in the wrong place, and corrupt internal interpreter state. If it _does_ modify anything, the interpreter might not detect state changes correctly (this is what happens, for example, if you use `gdb-inject-perl` to dump the call stack of a Perl process that is stuck in a blocking system call, via the `--signals` argument).

In short, it should not be used on a healthy process with important functionality that could be interrupted. "Interrupted", in this case, does not mean the same thing as a signal interrupt (Perl-safe or unsafe); it's possible to break/segfault/corrupt Perl in the midst of operations that would not normally be interruptible at all. *gdb-inject-perl* tries to mimic safe-signal delivery behavior, but does not do so perfectly.

### Where/when _should_ I use it?
`gdb-inject-perl` is recommended for use on processes that are already known to be deranged, and that are soon to be killed.

If a Perl process is stuck, broken, or otherwise malfunctioning, and you want more information than logs, `/proc`, `lsof`, `strace`, or any of the other standard [black-box debugging](http://jvns.ca/blog/2014/04/20/debug-your-programs-like-theyre-closed-source/) utilities can give you, you can use `gdb-inject-perl` to get more information.

# System Requirements

- Unix-ish OS.
    - OSX builds after Sierra are not compatible with this too; see [this issue](https://sourceware.org/bugzilla/show_bug.cgi?id=20981) for more information.
- GDB installed in a standard location, ideally on your `PATH`.
    - If `gdb` cannot be found on your system, the script will not start. If `gdb` is installed in a nonstandard location, set the `GDB` environment variable to its path before invoking the injector. For example: `GDB=/path/to/gdb perl gdb-inject-perl [options]`.
- Root privileges (usually; unless you're injecting to a process you own, in which case you do not need special permissions).
- Perl 5.8 or later
    - If `perl` cannot be found on the system, in the `PATH` or other common locations, the script will not start. You can use the `--force` switch to bypass this limitation (e.g. for running against embedded Perls); `gdb-inject-perl` itself does not require Perl to run.

# Safeguards and Limitations
There are a few basic safeguards used by *gdb-inject-perl*. 

- Code that will not compile with `strict` and `warnings` will be rejected. You can use the `--force` switch to run it anyway (at your own risk).
	- **Warning:** "Will it compile?" is checked using `perl -c`, which [will run `BEGIN` and `END` blocks](http://stackoverflow.com/a/12908487/249199). Such blocks will be executed during the pre-injection compilation check.  Besides, if code you plan on injecting into an already-running Perl process has `BEGIN` or `END` blocks, it's probably a bad idea.
- Code containing literal double quotation marks, even backslash-escaped ones, will be rejected. You can use the `--force` switch to run it anyway, but it will almost certainly not work.

# Signals

Sometimes, code is injected into a target process and not run. This is often because the target process is in the middle of a blocking system call (e.g. [`sleep`](http://linux.die.net/man/3/sleep)). In those situations, it is often useful to interrupt that system call by sending the target process a signal. To facilitate this, when target processes do not run injected code within a small amount of time, `inject.pl` prompts the user on the command line to send a signal (by name or number) to the target process, e.g.:

        ~> gdb-inject-perl --pid 1234 --signals
        The captive process is not responding. Send a signal to try to wake it up, or press CTRL+C to abort.
        WARNING: Waking a process with a signal will almost certainly crash it after debug output is acquired.
        Type a case-insensitive signal name or number ('sigint', 'INT', and '2' are equivalent), or 'L'/'?' to list available signals.
        Signal name, number, 'L' or '?': int
        Sent signal 2 to captive process (1234)
        ...stacktrace

Signals can be entered by number or name, case-insensitive. Pressing "L" triggers a listing of signals, similar to the behavior of `kill -l`.

*WARNING*: At the best of times, there's a significant risk that `gdb-inject-perl` will cause the target process to violently exit (segfault or similar). That risk is increased a *lot* if you use `--signals` to inject code into a blocking system call.

**Note:** the behavior of a target process after it has been signalled is _even more_ unknown than its behavior when running injected code without signals. While `gdb-inject-perl` tries to run the injected code before a process shuts down, signalling a target process often results in its termination immediately after running `CODE`. Also, since `gdb-inject-perl` uses the target process's internal Perl signal handling check as the attach point for the injected code, it is _not_ guaranteed that any internal (safe or unsafe) signal handlers already installed in the target process will run when it is signalled by `gdb-inject-perl`.

# FAQ

#### It doesn't work; it just says "GDB process timed out". What gives?
Your process is probably in a blocking system call or uninterruptible state (doing something other than just running Perl code). You can send it a signal and it might wake up and run your injected code. See [signals](#signals) for more info. If you don't want to use signals, try `strace` and friends.

#### After I used `gdb-inject-perl` on my process, it segfaulted/terminated/did something totally wrong! Why?
This is the cost of using an aggressive code injector. This tool does not take much care to preserve the pre-existing state of a perl process, and as a result often corrupts that state in such a way that Perl itself crashes with an unhandled error. `gdb-inject-perl` is dangerous and should only be run on processes you were willing to kill anyway.

#### On OSX it times out after saying "Unable to find Mach task port for process-id ___"
You need to [codesign the debugger](https://gcc.gnu.org/onlinedocs/gcc-4.8.0/gnat_ugn_unw/Codesigning-the-Debugger.html).

#### I want to inject something that changes my running program's state. Can I?
Sure, but don't come crying to me when it segfaults your application.

#### I want to inject code into multiple places inside a process. Can I?
Probably, but if you do, don't tell me how you pulled it off. It sounds like you need a [real](https://metacpan.org/pod/Devel::Trepan)[1] [debugger](http://search.cpan.org/~arc/perl/pod/perldebug.pod)[2].

#### Why not just use the Perl debugger/GDB directly?
- You might not need it. *gdb-inject-perl* is intended for a much, much simpler use case than the [Perl debugger](http://search.cpan.org/~arc/perl/pod/perldebug.pod) (or the excellent [Devel::Trepan](https://metacpan.org/pod/Devel::Trepan)): getting a little bit of context information out of a process that you might not know anything about.
	- **Simplicity is paramount**: the person monitoring and/or killing a Perl process might not know how to use the Perl debugger; they might not know what Perl is. Consider the example of a support technician or administrator that finds a process that is hung and breaking an important service: with *gdb-inject-perl*, they can run a command, send its output to the developers that maintain the service, and kill it as the normally would: no Perl understanding required.
- Debug symbols/Perl debugger support might not exist in your environment (certain embedded Perls, or bizarre system Perls). Even in those cases, the "caller" stack is usable for context information about a Perl process, and *gdb-inject-perl* can get it for you.

#### Why use FIFOs, and not use perl debugger's RemotePort functionality?
Something else might be using it. *gdb-inject-perl* is meant to be usable with minimal interference with other code running in a Perl process, _even other debuggers_.

#### Why is it written in Go, not Perl?

`gdb-inject-perl` was written in Perl eventually (and that version can still be used; it's in the `legacy-pure-perl` subdirectory of the source repository). So why the switch? A few reasons:

- Static Linking/Runtime Dependencies. Running the compiled Go version of `gdb-inject-perl` doesn't require Perl, Go, or any preinstalled software other than libc. If that seems pointless, consider the use case of debugging an embedded Perl interpreter (e.g. in `mod_perl` or similar) on a system that does not have a compatible or usable installation of the `perl` commandline utility. Systems without commandline Perls are admittedly rare, but also consider that some systems may not have Perl easily locatable on the `PATH`, and that different versions of Perl make different runtime assumptions and support different features, and that commandline-Perl may often be severely outdated, or custom-compiled for a system. While trying to get emergency debugging information from an embedded, opaque Perl process, having to stop and deal with the vagaries of operating system package configuration is far from ideal.
	- A commandline Perl interpreter is still required for testing custom `--code` values being injected. Testing can, however, be bypassed with the `--force` switch.
- Library Dependencies. The pure-Perl version had several CPAN modules as dependencies. For some users, installing CPAN modules in order to use a last-ditch debugging tool may take too much time, be out of the user's expertise level, or not be supported when running as the root user (which is required in order to use this script). Since Go is compiled and statically linked, it should be dependecy-free; even though third-party dependencies are used in the source code, end users don't have to remember to install them, provided they are running the version of `gdb-inject-perl` written for thier operating system.
- Concurrency. Even though `gdb-inject-perl` is very simple, it still needs low-level access to pipes, and needs to simultaneously wait for timeouts, user signals, or output from the process being inspected. This is totally possible in Perl, but, due to Perl's single-threaded nature and default buffering, requires careful coding around `sysread` and `select`, or the installation of additional CPAN dependencies. The implementation in the pure-Perl version of `gdb-inject-perl` is far from perfect, and is still nearly a hundred lines of relatively esoteric code. Go suports multiplexed event waiting by default, and also has more powerful standard-library facilities for dealing with pipes.

# Additional Resources
- Perlmonks [conversation about gdb-eval injection](http://www.perlmonks.org/?node_id=694095)
- Massive [presentation on various Perl debugging strategies, including this one](https://docs.google.com/presentation/d/1Lxk_YHUEV3k4dXJZlpsgUuph0PwmvpHbI8EX8Igy5rY/edit#slide=id.g11c288d8_0_35)
- [Script that does the same thing, but for threaded perl](https://gist.github.com/p120ph37/2bf794a86eeab0445658)
- [Devel::Trepan](https://metacpan.org/pod/Devel::Trepan)
- [Devel::GDB](https://metacpan.org/pod/Devel::GDB)
- The [Perl debugger](http://search.cpan.org/~arc/perl/pod/perldebug.pod)
- [Enbugger](https://metacpan.org/pod/distribution/Enbugger/lib/Enbugger.pod)
- [Zombie free linux with GDB](http://www.mattfiddles.com/computers/linux/zombie-slayer) (terrifying)
