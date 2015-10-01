#!/usr/bin/env perl
use strict;
use warnings;

use English qw( -no-match-vars );
use File::Temp qw( tempdir );

use File::Spec::Functions qw( catfile );
use POSIX qw( mkfifo );
use Getopt::Long qw( GetOptions );
use Pod::Usage qw( pod2usage );
use List::Util qw( first );
use IO::Select;

use File::Which qw( which );
use Capture::Tiny qw( capture tee capture_merged );

# Wait 5 seconds for data on the pipe, then bail.
use constant TIMEOUT => 5;

use constant GDBLINES => (
    "set confirm off",
    "set variable PL_sig_pending = 1",
    "b Perl_despatch_signals",
    "c",
    "delete breakpoints",
);

use constant TEMPLATE1 => q/{
    local $_;
    local $@;
    local $!;
    local @_;
    local %%SIG = %%SIG;
    local $| = 1;
    if ( open(my $fh, q{>}, q{%s}) ) {
        %s;
        print $fh qq{END %d-%d\n};
        close($fh);
    }
};/;

# Default code to inject.
use constant STACKDUMP => q/
unless ( exists($INC{'Carp.pm'}) ) {
    require Carp;
}
print $fh Carp::longmess('DEBUG');/;

use constant GDB_SEARCH_PATHS => (
    "/usr/bin/gdb",
    "/usr/local/bin/gdb" ,
    "/bin/gdb",
    $ENV{GDB},
    catfile( $ENV{HOMEBREW_ROOT}, "gdb" ),
    catfile( $ENV{HOMEBREW_ROOT}, "bin/gdb" ),
);

sub trim ($) {
    my $str = shift || "";
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

$OUTPUT_AUTOFLUSH = 1;

my $usage;
GetOptions(
    "pid:i" => \( my $pid ),
    "code:s" => \( my $code = STACKDUMP ),
    "force" => \( my $force ),
    "verbose" => \( my $verbose ),
    help => sub { return pod2usage( -verbose => 1, -exitval => 0, ); },
    man => sub { return pod2usage( -verbose => 2, -exitval => 0, ); },
) or pod2usage( -exitval => 2, -msg => "Invalid options supplied.\n" );

# Try *really hard* to find a GDB binary.
my $gdb = which("gdb") || first { -x $_ } GDB_SEARCH_PATHS;

unless ( $gdb ) {
    die "A usable GDB could not be found on the system.";
}

my $dir = tempdir( CLEANUP => 1 );

unless ( $force ) {
    unless ( index($code, '"') == -1 ) {
        die "Double quotation marks are not allowed in supplied code. Use --force to override."
    }

    my $inject = sprintf(TEMPLATE1, "/dev/null", $code, 0, $PROCESS_ID);

    print "Validating code to be injected. Generated code:\n$inject\n" if $verbose;

    my $testscript = catfile($dir, "test.pl");

    open(my $fh, ">", $testscript) or die "Could not open test script $testscript for writing: $OS_ERROR";
    print $fh "$inject\n";
    close $fh;

    my $perl = which("perl");
    my $combinedoutput = capture_merged{ system($perl, qw(-Mstrict -Mwarnings -c), $testscript); };
    my $exitcode = $CHILD_ERROR >> 8;
    if ( $exitcode || trim($combinedoutput) !~ qr/syntax OK/ ) {
        die sprintf(
            "Supplied code was not valid. Use --force to override.\nGenerated code:%s\nCompilation Output: %s\nCompilation exit status: %d",
            $inject,
            $combinedoutput,
            $exitcode,
        );
    } elsif ( $verbose ) {
        print "Compilation output: $combinedoutput\n\n";
    }
}

if ( ! $pid ) {
    pod2usage( -exitval => 2, -msg => "Pid is required (must be a number).\n" );
}

# End validation section.

my $fifo = catfile( $dir, "fifo" );
mkfifo($fifo, 0700) or die "Could not make FIFO: $OS_ERROR";

open (my $readhandle, "+<", $fifo) or die "Could not open FIFO for reading";

my $inject = sprintf(q{call Perl_eval_pv("%s", 0)}, sprintf(TEMPLATE1, $fifo, $code, $pid, $PROCESS_ID));

# Add slashes to the ends of newlines so GDB understands it as a multiline statement.
$inject =~ s/\n/\\\n/g;

my @command = ( $gdb, "-quiet", "-p", $pid, map { ("-ex", $_) } GDBLINES, $inject, "detach", "Quit");

if ( $verbose ) {
    tee { system(@command) };
} else {
    capture { system(@command) };
}

printf("GDB exited with status %d\n", $CHILD_ERROR >> 8) if $verbose;

my $select = IO::Select->new;
$select->add($readhandle);
unless ( $select->can_read(TIMEOUT) ) {
    die sprintf("Could not get debug information within %d seconds.", TIMEOUT);
}

my $line;
while ( ( $line = trim(<$readhandle>) ) && $line ne "END $pid-$PROCESS_ID" ) {
    print "$line\n";
}

__END__

=head1 NAME

inject.pl - Inject code into a running Perl process, using GDB. Dangerous, but useful for getting debug info in a pinch.

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

String of code that will be injected into the Perl process at PID and run. This code will have access to a special file handle, $fh, which connects it to inject.pl. When $fh is written to, the output will be returned by inject.pl. If CODE is ommitted, it defaults to printing the value of L<Carp::longmess> to $fh.

CODE should not perform complex alterations or change the state of the program being attached to.

CODE may not contain double quotation marks or Perl code that does not compile with L<strict> and L<warnings>. To bypass these restrictions, use --force.

=item B<--verbose>

Show all GDB output in addition to values captured from the process at PID.

=item B<--force>

Bypass sanity checks and restrictions on the content of CODE.

=item B<--help>

Show help message.

=item B<--man>

Show manpage/perldoc.

=back

=head1 DESCRIPTION

inject.pl is a script that uses GDB to attach to a running Perl process, and injects in a perl "eval" call with a string of code supplied by the user (it defaults to code that prints out the Perl call stack). If everything goes as planned, the Perl process in question will run that code in the middle of whatever else it is doing.

inject.pl is incredibly dangerous. It works by injecting arbitrary function calls into the runtime of a complex, high-level programming language (Perl). Even if the code you inject doesn't modify anything, it might be injected in the wrong place, and corrupt internal interpreter state. If it _does_ modify anything, the interpreter might not detect state changes correctly.

inject.pl is recommended for use on processes that are already known to be deranged, and that are soon to be killed.

=cut