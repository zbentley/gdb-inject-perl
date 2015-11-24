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
use Memoize;
use Pod::Usage qw( pod2usage );
use POSIX qw( mkfifo );
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
    print $fh Carp::longmess('DEBUG');/,
};

sub signals_by_order () { return split(' ', $Config{sig_name}); }
memoize('signals_by_order');

sub signals_by_name () { return map { $_ => 1 } signals_by_order(); }
memoize('signals_by_name');

sub signals_by_number () {
    my @byorder = signals_by_order();
    return map { $_ => $byorder[$_] } (1..scalar(@byorder) - 1);
}
memoize('signals_by_number');

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
        my %signals = signals_by_number;
        if ( $signals{$key} ) {
            $key = $signals{$key};
        }

        %signals = signals_by_name();
        if ( exists $signals{$key} ) {
            kill($key, $pid) or fatal("Kill failed: $OS_ERROR");
            info("Kill $key sent to $pid");
            $returnvalue = 1;
        } else {
            if ( $key ne "L" ) {
                info("Invalid entry. Please enter a number or signal name in the following listing:");
            }
            my $num = 0;
            print "Number:  Name:\n";
            foreach my $signal (signals_by_order()) {
                print ++$num . "\t$signal\n";
            }
            if ( $key ne "L" ) {
                $returnvalue = prompt_for_kill($pid, 0);
            }
        }
    }
    return $returnvalue;
}

sub capture_only_stdout_visible ($$$) {
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
memoize('end'); # Presumes that only one pid will be handled per script invocation.

sub get_parameters () {
    # my $pid;
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

    # Try *really hard* to find a GDB binary.
    my $gdb = which("gdb") || first { -x $_ } (
        "/usr/bin/gdb",
        "/usr/local/bin/gdb" ,
        "/bin/gdb",
        $ENV{GDB},
        catfile( $ENV{HOMEBREW_ROOT}, "gdb" ),
        catfile( $ENV{HOMEBREW_ROOT}, "bin/gdb" ),
    );

    if ( $signals ) {
        require Term::ReadKey;
    }

    unless ( $pid ) {
        pod2usage( -exitval => 2, -msg => "Pid is required (must be a number).\n" );
    }

    unless ( $gdb ) {
        fatal("A usable GDB could not be found on the system.");
    }

    if (! $force && index($code, '"') > -1) {
        fatal("Double quotation marks are not allowed in supplied code. Use --force to override.");
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

self_test_code($code, $dir) unless $force;

# End validation section.

my $fifo = catfile( $dir, "communication_pipe" );
mkfifo($fifo, 0700) or fatal("Could not make FIFO: $OS_ERROR");
sysopen(my $readhandle, $fifo, O_RDONLY | O_NONBLOCK) or fatal("Could not open FIFO for reading: $OS_ERROR");

my $inject = sprintf(q{call Perl_eval_pv("%s", 0)}, sprintf(TEMPLATE, $fifo, $code, end($pid)));

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
    && index($data, end($pid), length($data) - length(end($pid)) - 1) == -1
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
print "\n$data\n";

__END__

=head1 NAME

inject.pl - Inject code into a running Perl process, using GDB. Dangerous, but useful as a fast, simple way to get debug info.

=head1 SYNOPSIS

To dump the call stack of a running process:

    # Run something in the background that has a particular call stack:

    perl -e 'sub Foo { my $stuff = shift; eval $stuff; } sub Bar { Foo(@_) }; eval { Bar("while (1) { sleep 1; }"); };' &
    inject.pl --pid $!

    # DEBUG at (eval 1) line 1.
    # eval 'while (1) { sleep 1; }
    # ;' called at -e line 1
    # main::Foo(undef) called at -e line 1
    # main::Bar('while (1) { sleep 1; }') called at -e line 1
    # eval {...} called at -e line 1

To run arbitrary code in a running process:

    inject.pl --pid <SOMEPID> --code 'print STDERR qq{FOOO $$}; sleep 1;'
    # FOOO <SOMEPID> # printed from other process

    inject.pl --pid <SOMEPID> --code 'print $fh STDERR qq{FOOO $$}; sleep 1;'
    # FOOO <SOMEPID> # printed from gdb-inject-perl


=head1 OPTIONS

=over 8

=item B<--pid PID>

Process ID of the Perl process to inject code into. PID can be any kind of Perl process: embedded, mod_perl, simple script etc.

This option is required.

=item B<--code CODE>

String of code that will be injected into the Perl process at PID and run. This code will have access to a special file handle, $fh, which connects it to inject.pl. When $fh is written to, the output will be returned by inject.pl. If C<CODE> is omitted, it defaults to printing the value of L<Carp::longmess> to $fh.

C<CODE> should not perform complex alterations or change the state of the program being attached to.

C<CODE> may not contain double quotation marks or Perl code that does not compile with L<strict> and L<warnings>. To bypass these restrictions, use --force.

=item B<--verbose>

Show all GDB output in addition to values captured from the process at C<PID>.

=item B<--force>

Bypass sanity checks and restrictions on the content of C<CODE>.

=item B<--timeout SECONDS>

Number of seconds to wait until C<PID> runs C<CODE>. If the timeout is exceeded (usually because C<PID> is in the middle of a blocking system call), C<inject.pl> gives up.

Defaults to 5.

=item B<--help>

Show help message.

=item B<--man>

Show manpage/perldoc.

=back

=head1 DESCRIPTION

C<inject.pl> is a script that uses GDB to attach to a running Perl process, and injects in a perl "eval" call with a string of code supplied by the user (it defaults to code that prints out the Perl call stack). If everything goes as planned, the Perl process in question will run that code in the middle of whatever else it is doing.

C<inject.pl> is incredibly dangerous. It works by injecting arbitrary function calls into the runtime of a complex, high-level programming language (Perl). Even if the code you inject doesn't modify anything, it might be injected in the wrong place, and corrupt internal interpreter state. If it B<does> modify anything, the interpreter might not detect state changes correctly.

C<inject.pl> is recommended for use on processes that are already known to be deranged, and that are soon to be killed.

=cut