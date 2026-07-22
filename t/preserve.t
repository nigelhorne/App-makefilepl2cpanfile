use strict;
use warnings;
use Test::Most;
use App::makefilepl2cpanfile;

# This test uses the repository's own Makefile.PL as the input, which is
# intentional: it exercises generate() against a real, non-trivial file.

my $existing_cpanfile = <<'END_CPANFILE';
on 'develop' => sub {
  requires 'Foo::Bar';
};
END_CPANFILE

my $out = App::makefilepl2cpanfile::generate(
	makefile     => 'Makefile.PL',
	existing     => $existing_cpanfile,
	with_develop => 1,
);

# Hand-curated entry from the existing cpanfile must survive regeneration.
like $out, qr/Foo::Bar/, 'hand-curated develop entry is preserved';

# The existing entry must not be duplicated.
my @hits = ($out =~ /Foo::Bar/g);
is scalar @hits, 1, 'preserved entry appears exactly once';

done_testing;
