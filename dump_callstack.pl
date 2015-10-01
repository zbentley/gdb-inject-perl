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
use Capture::Tiny qw( capture tee );

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
    local %%INC = %%INC;
    local @INC = @INC;
    local %%SIG = %%SIG;
    local $| = 1;
    if ( open(my $fh, q{>}, q{%s}) ) {
        %s;
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

local $OUTPUT_AUTOFLUSH = 1;

my $usage;
GetOptions(
    "pid:i" => \( my $pid ),
    "timeout:i" => \( my $timeout = TIMEOUT ),
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

    my $inject = sprintf(TEMPLATE1, "/dev/null", $code);
    my $testscript = catfile($dir, "test.pl");

    open(my $fh, ">", $testscript) or die "Could not open test script $testscript for writing: $OS_ERROR";
    print $fh "$inject\n";
    close $fh;

    my $perl = which("perl");
    my $combinedoutput = qx/$perl -Mstrict -Mwarnings -c $testscript 2>&1/;
    my $exitcode = $CHILD_ERROR >> 8;
    if ( $exitcode || trim($combinedoutput) !~ qr/syntax OK/ ) {
        die sprintf(
            "Supplied code was not valid. Use --force to override.\nGenerated code:%s\nCompilation Output: %s\nCompilation exit status: %d",
            $inject,
            $combinedoutput,
            $exitcode,
        );
    }
}

if ( ! $pid ) {
    pod2usage( -exitval => 2, -msg => "Pid is required (must be a number).\n" );
}

# End validation section.

my $fifo = catfile( $dir, "fifo" );
mkfifo($fifo, 0700) or die "Could not make FIFO: $OS_ERROR";

my $inject = sprintf(q{call Perl_eval_pv("%s", 0)}, sprintf(TEMPLATE1, $fifo, $code));

# Add slashes to the ends of newlines so GDB understands it as a multiline statement.
$inject =~ s/\n/\\\n/g;

my @command = ( $gdb, "-quiet", "-p", $pid, map { ("-ex", $_) } GDBLINES, $inject, "detach", "Quit", ">/dev/null");

if ( $verbose ) {
    tee { system(@command) };
} else {
    capture { system(@command) };
}
printf("GDB exited with status %d", $CHILD_ERROR >> 8) if $verbose;

open (my $readhandle, "+<", $fifo) or die "Could not open FIFO for reading";

my $select = IO::Select->new;
$select->add($readhandle);
unless ( $select->can_read($timeout) ) {
    die "Did not get info from process within $timeout seconds.";
}

while ( $select->can_read(0.25) ) {
    print <$readhandle>;
}

exit;

__END__

=head1 NAME

=head1 SYNOPSIS

=head1 OPTIONS

=over 8

=item B<--help>

Show help message.

=item B<--man>

Show manpage/perldoc.

=back

=cut