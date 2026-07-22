use strict;
use warnings;
use Test::Most;
use File::Temp qw(tempdir);
use Path::Tiny;

BEGIN { use_ok('App::makefilepl2cpanfile') }

my $dir = tempdir(CLEANUP => 1);
chdir $dir;

path('Makefile.PL')->spew_utf8(<<'END_MF');
WriteMakefile(
	MIN_PERL_VERSION => '5.010',
	PREREQ_PM => { 'Try::Tiny' => 0 },
);
END_MF

my $out = App::makefilepl2cpanfile::generate(makefile => 'Makefile.PL');

like $out, qr/requires 'Try::Tiny'/,     'runtime dep is present';
like $out, qr/'perl', '5.010'/,          'MIN_PERL_VERSION is emitted';
like $out, qr/^# Generated from/m,       'header comment is present';

# A versioned dependency must include the version constraint.
path('Makefile.PL')->spew_utf8(<<'END_MF');
WriteMakefile(
	PREREQ_PM => { 'Foo::Bar' => '1.23' },
);
END_MF

my $versioned = App::makefilepl2cpanfile::generate(
	makefile     => 'Makefile.PL',
	with_develop => 0,
);
like $versioned, qr/requires 'Foo::Bar', '1\.23'/, 'version constraint is emitted';

done_testing;
