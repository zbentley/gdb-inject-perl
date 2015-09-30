Where/when can I use this?

It works on scripts. 
It works on mod_perl processes.
It works on other CGI Perls inside webservers.
It works on (some) embedded Perls.

So what's the catch?
It's incredibly dangerous.
<WHY>
It's recommended for use on processes that are already known to be deranged, and that are soon to be killed.

I want to do something that changes my program's state inside the injected Perl. Can I?
Sure, but don't come crying to me if it segfaults your application.

I want to inject code into multiple places inside a process. Can I?
- Probably, but if you do, don't tell me how you pulled it off. It sounds like you need a [real] [debugger].

Why not just use the Perl debugger?
- You might not need it. This is intended for a much, much simpler use case than the debugger (or the excellent trepan): getting a little bit of context information out of a process that you might not know anything about. This tool is intended to be used as a very early-phase debugging step to gather information about a process before it is killed. As a result, simplicity is paramount: the person monitoring and/or killing a Perl process might not know how to use the Perl debugger; they might not be a developer at all.
- Debug symbols/Perl debugger support might not exist in certain embedded environments, or with certain bizarre system Perls. Even in those cases, the "caller" stack is usable for context information about a Perl process.

Why not use the perl debugger's RemotePort functionality?
Something else might be using it. This is meant to be usable with minimal disturbance of existing things, _even other debuggers_.



TODO:
- License
- Enable/disable C backtrace.
- Tests
- Thread support
- Custom stack-dumping modules (must "can" longmess)
- Better option parsing.
- Absolute-path GDB
- Check prerequisites before starting (gdb)
- Arbitrary Perl code to execute.
- Execute code from commandline or from file.

THANKS:
- Jesse Moeller
- Eugene Marcotte
- diotalevi http://www.perlmonks.org/?node_id=194920
- p120ph37

See also:
- Zombie free linux
- Enbugger
- http://www.perlmonks.org/?node_id=694095
- https://docs.google.com/presentation/d/1Lxk_YHUEV3k4dXJZlpsgUuph0PwmvpHbI8EX8Igy5rY/edit#slide=id.g11c288d8_0_35
- https://gist.github.com/p120ph37/2bf794a86eeab0445658
- https://metacpan.org/pod/Devel::Trepan
- http://search.cpan.org/~arc/perl/pod/perldebug.pod