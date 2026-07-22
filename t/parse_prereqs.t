use strict;
use warnings;
use Test::Most;
use App::makefilepl2cpanfile;

# parse_prereqs() is a public function: test it independently of generate().

my $content = <<'END_MF';
WriteMakefile(
	PREREQ_PM => {
		'Moo'       => '2.000',
		'Try::Tiny' => 0,
	},
	TEST_REQUIRES => {
		'Test::More' => 0,
	},
	CONFIGURE_REQUIRES => {
		'ExtUtils::MakeMaker' => '6.64',
	},
	BUILD_REQUIRES => {
		'Module::Build' => '0.42',
	},
);
END_MF

my $deps = App::makefilepl2cpanfile::parse_prereqs($content);

isa_ok $deps, 'HASH', 'parse_prereqs returns a hashref';

# Runtime phase
ok exists $deps->{runtime}{'Moo'},       'Moo is in runtime';
is $deps->{runtime}{'Moo'}, '2.000',     'Moo carries its version';
ok exists $deps->{runtime}{'Try::Tiny'}, 'Try::Tiny is in runtime';
is $deps->{runtime}{'Try::Tiny'}, 0,     'Try::Tiny version is 0';

# Test phase
ok exists $deps->{test}{'Test::More'}, 'Test::More is in test';

# Configure phase
ok exists $deps->{configure}{'ExtUtils::MakeMaker'}, 'ExtUtils::MakeMaker in configure';
is $deps->{configure}{'ExtUtils::MakeMaker'}, '6.64', 'ExtUtils::MakeMaker version correct';

# Build phase
ok exists $deps->{build}{'Module::Build'}, 'Module::Build is in build';
is $deps->{build}{'Module::Build'}, '0.42', 'Module::Build version correct';

# 'develop' must not be present — parse_prereqs does not inject it.
ok !exists $deps->{develop}, 'develop phase is absent (injected by generate, not parse_prereqs)';

# Inline comments must be stripped before extraction.
my $commented = <<'END_MF';
WriteMakefile(
	PREREQ_PM => {
		'Foo::Bar' => 0,    # used by something
		# 'Ignored::Module' => 0,
	},
);
END_MF

my $dep2 = App::makefilepl2cpanfile::parse_prereqs($commented);
ok  exists $dep2->{runtime}{'Foo::Bar'},       'uncommented module is extracted';
ok !exists $dep2->{runtime}{'Ignored::Module'}, 'fully-commented module is not extracted';

done_testing;
