{
    local $_;
    local $@;
    local $!;
    local @_;
    local %SIG = %SIG;
    local $| = 1;
    if ( open(my $fh, q{>}, q{/dev/null}) ) {
        
unless ( exists($INC{'Carp.pm'}) ) {
    require Carp;
}
print $fh Carp::longmess('DEBUG');;
        print $fh qq{END 0-76916\n};
        close($fh);
    }
};
