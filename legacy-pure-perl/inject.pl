#!/usr/bin/env perl
use strict;
use warnings;

use English qw( -no-match-vars );

use Capture::Tiny qw( tee tee_stdout capture_merged capture_stderr );
use Config;
use Fcntl;
use File::Spec::Functions qw( catfile splitpath );
use File::Temp qw( tempdir );
use File::Which qw( which );
use Getopt::Long qw( GetOptions );
use IPC::Run ();
use List::Util qw( first );
use Pod::Usage qw( pod2usage );
use POSIX qw( mkfifo );
use Term::ReadKey;
use Time::HiRes ();

my $DEBUG;
local $OUTPUT_AUTOFLUSH = 1;

use constant {
    GDBLINES => [
        # Don't ask questions on the command line.
        "set confirm off",
        # Pass signals through to Perl without stopping the debugger.
        "handle all noprint nostop",
        # Register a pending signal with Perl.
        "set variable PL_sig_pending = 1",
        # Stop when we get to the safe-ish signal handler.
        "b Perl_despatch_signals",
        # Wait for signalling to happen.
        "c",
        "delete breakpoints",
    ],
    TEMPLATE => q/{
        local $_;
        local $@;
        local $!;
        local @_;
        local %%SIG = %%SIG;
        local $| = 1;
        if ( open(my $fh, q{>}, q{%s}) ) {
            %s;
            print $fh qq{%s\n};
            close($fh);
        }
    };/,
    GDB_FAILURE_STRINGS => [
        "Can't attach to process",
        "Operation not permitted",
        "The program is not being run",
    ],
    # Default code to inject.
    STACKDUMP => q/
    unless ( exists($INC{'Carp.pm'}) ) {
        require Carp;
    }
    print $fh Carp::longmess('INJECT');/,
};

sub trim ($) {
    my $str = shift || "";
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

sub poll_sleep () { return Time::HiRes::sleep(0.25) ? 0.25 : 0; }

# Logging functions to deliniate between output from this script and output from
# the commands it runs.
sub debug ($) { return $DEBUG ? print logline(@_) : undef; }

sub info ($) { return print logline(@_); }

sub fatal ($) { die logline(@_); }

sub logline ($) {
    my ( $msg ) = @_;
    return sprintf(
        "[%s] %s\n",
        (splitpath($PROGRAM_NAME))[2],
        trim($msg)
    );
}

sub prompt_for_kill ($$);
sub prompt_for_kill ($$) {
    my ( $pid, $sent ) = @_;
    my $returnvalue;
    unless ( $sent ) {
        info("Press a number key to send a signal to $pid. Press 'l' or 'L' to list signals.");
    }
    if ( my $key = uc(trim(Term::ReadKey::ReadKey(-1))) ) {
        my @numbers = split(qr/\s+/, $Config{sig_num});
        my @names = split(qr/\s+/, $Config{sig_name});

        my $sig = first { $_ eq $key } @names;
        if ( ! $sig && ( my $idx = first { $key == $numbers[$_] } (0..scalar(@numbers) - 1) )) {
            $sig = $names[$idx];
        }

        if ( $sig && $sig ne "ZERO" ) {
            kill($sig, $pid) or fatal("Kill failed: $OS_ERROR");
            info("SIG$sig sent to $pid");
            $returnvalue = 1;
        } else {
            if ( $key ne "L" ) {
                info("Invalid entry. Please enter a number or signal name in the following listing:");
            }

            print "Number:  Name:\n";
            foreach my $cur (1..scalar(@names) - 1) {
                 printf("%d\t%s\n", $numbers[$cur], $names[$cur]);
            }

            if ( $key ne "L" ) {
                $returnvalue = prompt_for_kill($pid, 0);
            }
        }
    }
    return $returnvalue;
}

# Capture both STDOUT and STDERR, but only print STDOUT while doing it.
sub capture_only_stdout_visible ($) {
    my ( $code, $out, $err ) = @_;
    $out = tee_stdout { $err = capture_stderr(\&{$code}) };
    return ( $out, $err );
}

sub run_command ($$$$@) {
    my ( $pid, $runner, $timeout, $prog ) = splice(@_, 0, 4);
    my @args = @_;
    my $fork;
    my $skip;
    my ( $stdout, $stderr ) = $runner->(sub {
        $fork = IPC::Run::start([ $prog, @args ]);
        my $sent = -1;
        while ( $timeout > 0 && $fork->pumpable ) {
            if ( $pid && prompt_for_kill($pid, $sent++) ) {
                $skip = 1;
            } elsif ( ! $skip ) {
                $timeout -= poll_sleep();
            } else {
                # Prevent an extra long-sleep while any sent signals are processed
                # by doing a short sleep here.
                sleep 0.02;
                $skip = 0;
            }
        }

        return debug(sprintf("%s exited with status %d", $prog, $CHILD_ERROR >> 8));
    });

    if ( $timeout ) {
        $fork->finish;
    } else {
        $fork->kill_kill(grace => 5);
        $fork->finish;
        fatal("Execution of $prog timed out. Captured stdout:\n$stdout\nCaptured stderr:\n$stderr");
    }

    if ( grep { index($stderr, $_) > -1} @{+GDB_FAILURE_STRINGS} ) {
        fatal("Error running $prog.\nCaptured stdout:\n$stdout\nCaptured stderr:\n$stderr");
    }
    return;
}

sub end ($) { return "END $_[0]-$PROCESS_ID"; }

sub get_parameters () {
    GetOptions(
        # TODO assert positive
        "pid:i" => \ ( my $pid ),
        # TODO assert positive
        "timeout:i" => \( my $timeout = 5 ),
        "code:s" => \( my $code = STACKDUMP ),
        "force" => \( my $force ),
        "verbose" => \$DEBUG,
        "signals!" => \( my $signals = 1 ),

        help => sub { return pod2usage( -verbose => 1, -exitval => 0, ); },
        man => sub { return pod2usage( -verbose => 2, -exitval => 0, ); },
    ) or pod2usage( -exitval => 2, -msg => "Invalid options supplied.\n" );

    unless ( $pid ) {
        pod2usage( -exitval => 2, -msg => "Pid is required (must be a number).\n" );
    }

    # Try *really hard* to find a GDB binary.
    my $gdb = which("gdb") || first { -x defined($_) ? $_ : "" } (
        "/usr/bin/gdb",
        "/usr/local/bin/gdb" ,
        "/bin/gdb",
        $ENV{GDB},
        catfile( $ENV{HOMEBREW_ROOT}, "gdb" ),
        catfile( $ENV{HOMEBREW_ROOT}, "bin/gdb" ),
    );

    unless ( $gdb ) {
        fatal("A usable GDB could not be found on the system.");
    }

    if ( $signals ) {
        fatal("Platform does not support signals; try using --nosignals instead") unless $Config{sig_num};
        require Term::ReadKey;
    }

    if (! $force && index($code, '"') > -1) {
        fatal("Double quotation marks are not allowed in supplied code. Use '--force' to override.");
    }

    return ( $pid, $code, $timeout, $force, $signals, $gdb );
}

# Make sure that the supplied code compiles.
sub self_test_code ($$) {
    my ( $code, $dir ) = @_;
    my $inject = sprintf(TEMPLATE, "/dev/null", $code, 0, $PROCESS_ID);

    debug("Validating code to be injected. Generated code:\n$inject\n");

    my $testscript = catfile($dir, "self_test.pl");

    open(my $fh, ">", $testscript) or fatal("Could not open test script $testscript for writing: $OS_ERROR");
    print $fh "$inject\n";
    close $fh;

    my $perl = which("perl");
    my $combinedoutput = capture_merged { system($perl, qw(-Mstrict -Mwarnings -c), $testscript); };
    my $exitcode = $CHILD_ERROR >> 8;
    if ($exitcode || trim($combinedoutput) !~ qr/syntax OK/) {
        fatal(sprintf(
            "Supplied code was not valid. Use --force to override.\nGenerated code:%s\nCompilation Output: %s\nCompilation exit status: %d",
            $inject,
            $combinedoutput,
            $exitcode,
        ));
    }

    return debug("Compilation output: $combinedoutput");
}

my ( $pid, $code, $timeout, $force, $signals, $gdb ) = get_parameters();

# Make the tempdirs look at least somewhat meaningful on the filesystem.
my $dir = tempdir(
    join("-", $PROGRAM_NAME, $pid, "X" x 5),
    CLEANUP => 1,
    TMPDIR => 1,
);
chmod(0777, $dir) or fatal("Could not chmod temporary drectory $dir: $OS_ERROR");
debug("Using temp directory $dir");

self_test_code($code, $dir) unless $force;
# End validation section.

my $fifo = catfile( $dir, "communication_pipe" );
# Make the FIFO with promiscuous permissions, since it's temporary and it's
# better to be safe than sorry.
mkfifo($fifo, 0777) or fatal("Could not make FIFO: $OS_ERROR");
chmod(0777, $fifo) or fatal("Could not chmod FIFO: $OS_ERROR");
sysopen(my $readhandle, $fifo, O_RDONLY | O_NONBLOCK) or fatal("Could not open FIFO for reading: $OS_ERROR");
debug("Using FIFO $fifo");

my $end = end($pid);
my $inject = sprintf(
    q{call Perl_eval_pv("%s", 0)},
    sprintf(TEMPLATE, $fifo, $code, $end),
);

# Add slashes to the ends of newlines so GDB understands it as a multiline statement.
$inject =~ s/\n/\\\n/g;

run_command(
    $signals ? $pid : undef,
    $DEBUG ? \&tee : \&capture_only_stdout_visible,
    $timeout,
    $gdb,
    "-quiet",
    "-p",
    $pid,
    ( map { ("-ex", $_) } @{+GDBLINES}, $inject, "detach", "Quit" ),
);

# In signals mode, log which prompting phase we're at.
my $log = $signals ? \&info : \&debug;
$log->("Injected code; waiting for stack output...");

my $data = "";
my $sent = -1;
while (
    $timeout > 0
    && index($data, $end, length($data) - length($end) - 1) < 0
    && -p $fifo
) {
    my $chunk;
    if ( defined ( my $read = sysread($readhandle, $chunk, 1024) ) ) {
        if ( $read ) {
            # Greedily read so long as there's data in the pipe.
            $data .= $chunk;
        } elsif ( ! ( $signals && prompt_for_kill($pid, $sent++) ) ) {
            # Emulate select()-like waiting if we didn't issue a kill.
            $timeout -= poll_sleep();
        }
    } else {
        fatal("Error while reading from FIFO: $OS_ERROR\n\nGot data: $data");
    }
}

debug("Got data:");
if ( my $endmarker = index($data, $end)) {
    $data = substr($data, $endmarker);
}
print "\n$data\n";
exit(0);

__END__

=head1 NAME

inject.pl - Inject code into a running Perl process, using GDB. Dangerous, but useful as a fast and simple way to get debug info.

See L<https://github.com/zbentley/gdb-inject-perl>.

=head1 SYNOPSIS

To dump the call stack of a running process:

    ~> inject.pl --pid 1234

    INJECT at (eval 1) line 1. # Current call stack of process 1234:
    eval 'while (1) { sleep 1; }
    ;' called at -e line 1
    main::Foo(undef) called at -e line 1
    main::Bar('while (1) { sleep 1; }') called at -e line 1
    eval {...} called at -e line 1

To run arbitrary code in a running process:

    ~> inject.pl --pid 1234 --code 'print STDERR qq{FOOO $$}; sleep 1;'
    FOOO 1234 # printed from other process

    ~> inject.pl --pid <SOMEPID> --code 'print $fh STDERR qq{FOOO $$}; sleep 1;'
    FOOO 6789 # printed from gdb-inject-perl


=head1 OPTIONS

=over 8

=item B<--pid PID>

Process ID of the Perl process to inject code into. C<PID> can be any kind of Perl process: embedded, mod_perl, simple script, etc.

This option is required.

=item B<--code CODE>

String of code that will be injected into the Perl process at C<PID> and run. This code will have access to a special file handle, C<$fh>, which connects it to C<inject.pl>. When C<$fh> is written to, the output will be returned by C<inject.pl>. If C<CODE> is omitted, it defaults to printing the value of L<Carp::longmess|https://metacpan.org/pod/Carp> to C<$fh>.

C<CODE> should not perform complex alterations or change the state of the program being attached to.

C<CODE> may not contain double quotation marks or Perl code that does not compile with L<strict|hhttps://metacpan.org/pod/strict> and L<warnings|https://metacpan.org/pod/warnings>. To bypass these restrictions, use C<--force>.

=item B<--force>

Bypass sanity checks and restrictions on the content of C<CODE>.

=item B<--[no]signals>

Enable or disable the option to send signals to the process at C<PID>. If C<--signals> is enabled, once C<inject.pl> has injected code into the process at C<PID>, the user will be prompted to send signals to C<PID> in order to interrupt any blocking system calls and force C<CODE> to be run. See L</Signals> for more info.

Defaults to enabled. If L<Term::ReadKey|https://metacpan.org/pod/Term::ReadKey> is not installed on your system, disabling signals via C<--nosignals> bypasses thie requirement for that module.

=item B<--timeout SECONDS>

Number of seconds to wait until C<PID> runs C<CODE>. If the timeout is exceeded (usually because C<PID> is in the middle of a blocking system call), C<inject.pl> gives up.

Defaults to 5.

=item B<--verbose>

Show all GDB output in addition to values captured from the process at C<PID>.

=item B<--help>

Show help message. For more detailed information and examples, use C<--man>.

=item B<--man>

Show manpage/perldoc, including behavior description, caveats, examples, amd more.

=back

=head1 DESCRIPTION

C<inject.pl> is a script that uses L<gdb|http://linux.die.net/man/1/gdb> to attach to a running Perl process, and injects in a perl "eval" call with a string of code supplied by the user (it defaults to code that prints out the Perl call stack). If everything goes as planned, the Perl process in question will run that code in the middle of whatever else it is doing.

=head2 Caveats

B<C<inject.pl> is incredibly dangerous>. It works by injecting arbitrary function calls into the runtime of a complex, high-level programming language (Perl). Even if the code you inject doesn't modify anything, it might be injected in the wrong place, and corrupt internal interpreter state. If it I<does> modify anything, the interpreter might not detect state changes correctly.

C<inject.pl> is recommended for use on processes that are already known to be deranged, and that are soon to be killed.

=head2 Examples

For a contrived example, run some Perl  in the background that has a particular call stack:

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
    
Then use C<inject.pl> on the backgrounded process, and observe its call stack:

    ~> inject.pl --pid 1234
    DEBUG at (eval 1) line 1.
    eval 'while (1) { sleep 1; }
    ;' called at -e line 1
    main::Foo(undef) called at -e line 1
    main::Bar('while (1) { sleep 1; }') called at -e line 1
    eval {...} called at -e line 1

=head2 Signals

Sometimes, code is injected into a target process and not run. This is often because the target process is in the middle of a blocking system call (e.g. L<C<sleep>|http://linux.die.net/man/3/sleep>). In those situations, it is often useful to interrupt that system call by sending the target process a signal. To facilitate this, when target processes do not run injected code within a small amount of time, C<inject.pl> prompts the user on the command line to send a signal (by name or number) to the target process, e.g.:

    ~> inject.pl --pid 1234
    [inject.pl] Press a number key to send a signal to 1234. Press 'l' or 'L' to list signals.
    int
    [inject.pl] SIGINT sent to 1234

    # Signals can also be entered by number:
    [inject.pl] Press a number key to send a signal to 1234. Press 'l' or 'L' to list signals.
    15
    [inject.pl] SIGTERM sent to 1234

Signals can be entered by number or name, case-insensitive. Pressing "L" triggers a listing of signals, similar to the behavior of C<kill -l>.

B<Note:> the behavior of a target process after it has been signalled is I<even more> unknown than its behavior when running injected code without signals. While C<inject.pl> tries to run the injected code before a process shuts down, signalling a target process often results in its termination immediately after running C<CODE>. Also, since C<inject.pl> uses the target process's internal Perl signal handling check as the attach point for the injected code, it is I<not> guaranteed that any internal (safe or unsafe) signal handlers already installed in the target process will run when it is signalled by C<inject.pl>. 

=cut