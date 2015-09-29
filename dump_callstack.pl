#!/usr/bin/env perl
use strict;
use warnings;

use Data::Printer;

use Fcntl;

local $| = 1;

use constant GDBLINES => (
        "set confirm off",
        "set variable PL_sig_pending = 1",
        "b Perl_despatch_signals",
        "c",
        "delete breakpoints"
);

use constant TEMPLATE1 => q#call Perl_eval_pv("{
        local $_;
        local $@;
        local $!;
        local @_;
        local %INC = %INC;
        local @INC = @INC;
        local %SIG = %SIG;
        local $| = 1;#;

use constant TEMPLATE2 => q#
	if ( open(my $fh, '>', '%s') ) {
		%s;
		close($fh);
        }
}", 0)#;

use constant STACKDUMP => q#
unless ( exists($INC{'Carp.pm'}) ) {
        require Carp;
}

print $fh Carp::longmess('DEBUG');#;


my $pid = $ARGV[0];

use File::Temp qw(tempdir);
use File::Spec::Functions qw(catfile);
use POSIX qw(mkfifo);

my $dir = tempdir(CLEANUP=>1);
my $fifo = catfile($dir, "fifo0");
mkfifo($fifo, 0700) or die "Could not make FIFO: $!";

my $inject = TEMPLATE1 . sprintf(TEMPLATE2, $fifo, STACKDUMP);

$inject =~ s/\n/\\\n/g;

my @command = map { ("-ex", $_) } GDBLINES, $inject, "detach", "Quit";

open (my $readhandle, "+<", $fifo) or die "Could not open FIFO for reading";

use IPC::System::Simple qw( capturex );

my $output = capturex("gdb", "-p", $pid, @command);

print $output;

while(my $line = <$readhandle>) {
	print $line;
}

exit;

# my $child = fork();
# if ( $child > 0 ) {
#         close(WRITE) or warn "Could not close write handle in parent: $!";
#         waitpid(-1, 0) or warn "Could not reap children: $!";
#         while (my $line = <READ>) {
#                 print "$line\n";
#         }
# } else {
#         close(READ) or die "Could not close read handle in child: $!";
        
#         fcntl(WRITE, F_SETFD, 0) or die $!;
# 	#exec("gdb", "-p", $pid, @command);
# 	#exec("perl", "-e", qq{
#                # sleep 100;
# 	#	local \$| = 1;
#         #        open(my \$fh, ">>&=", __) or die \$!;
#         #        print \$fh "FOOO\n" or die \$!;
#         #});
# 	# exec("gdb", "-p", $pid, @command);
# }
