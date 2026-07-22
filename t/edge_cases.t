use strict;
use warnings;

# Destructive, boundary-condition, pathological, and security tests.
#
# Two bugs were discovered during test authoring and fixed in the library:
#
#   BUG 1 — parse_prereqs: undef / reference input emitted Perl warnings.
#     The POD states "No errors or warnings — unrecognised content is silently
#     ignored."  Passing undef caused "Use of uninitialized value" warnings
#     from the pattern-match operators; a reference caused "reference used as
#     string" warnings.
#     FIX: return {} early when $content is undef or a reference.
#
#   BUG 2 — generate: develop-block merge truncated at '}; ' inside comments.
#     The regex /\{(.*?)\};/s terminated at the FIRST '};' anywhere in the
#     existing text, including inside inline comments, silently dropping any
#     module entries that followed the comment.
#     FIX: anchor the terminator to the start of a line (^}; with /m).

use Test::Most;
use Test::Mockingbird;
use File::Temp qw(tempdir);
use Path::Tiny;
use Readonly;
use YAML::Tiny;

use App::makefilepl2cpanfile;

# -----------------------------------------------------------------------
# Shared constants and helpers
# -----------------------------------------------------------------------

Readonly my $MF_SIMPLE =>
	"WriteMakefile(PREREQ_PM => { 'Carp' => 0 });\n";

# Return a mock_scoped guard that routes File::HomeDir::my_home to an
# empty temp directory, isolating tests from the developer's real config.
sub empty_home {
	my $h = tempdir(CLEANUP => 1);
	return mock_scoped 'File::HomeDir::my_home' => sub { $h };
}

# Return a mock_scoped guard whose config directory contains a custom
# makefilepl2cpanfile.yml constructed from the supplied hashref.
sub home_with_config {
	my ($data) = @_;
	my $h = tempdir(CLEANUP => 1);
	path($h)->child('.config')->mkpath;
	YAML::Tiny->new($data)
		->write(
			path($h)->child('.config', 'makefilepl2cpanfile.yml')->stringify
		);
	return mock_scoped 'File::HomeDir::my_home' => sub { $h };
}

# Write $content to a fresh Makefile.PL in a temp dir and return its path.
sub make_mf {
	my ($content) = @_;
	my $dir = tempdir(CLEANUP => 1);
	my $mf = path($dir)->child('Makefile.PL');
	$mf->spew_utf8($content);
	return $mf;
}

# -----------------------------------------------------------------------
# SECTION 1: parse_prereqs — hostile and pathological inputs
# -----------------------------------------------------------------------

subtest 'parse_prereqs: undef input returns empty hashref with no warnings' => sub {
	# BUG 1 (fixed): before the fix, this emitted "Use of uninitialized value".
	# Strategy: capture all warnings via $SIG{__WARN__} and assert the list
	# is empty after the call, verifying the POD contract.
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $result;
	lives_ok { $result = App::makefilepl2cpanfile::parse_prereqs(undef) }
		'parse_prereqs(undef) does not die';

	isa_ok $result, 'HASH', 'undef input returns a hashref';
	is scalar keys %{$result}, 0, 'result is empty for undef input';
	is scalar @warnings, 0,
		'no warnings emitted (POD: "No errors or warnings")';

	diag "Captured warnings: @warnings" if $ENV{TEST_VERBOSE} && @warnings;
};

subtest 'parse_prereqs: reference inputs return empty hashref with no warnings' => sub {
	# BUG 1 (fixed): passing a reference caused "reference used as string"
	# warnings.  Strategy: cycle through four reference types and verify
	# each produces an empty hashref silently.
	Readonly my @CASES => (
		[ 'ARRAY ref',  []       ],
		[ 'HASH ref',   {}       ],
		[ 'CODE ref',   sub {}   ],
		[ 'SCALAR ref', \42      ],
	);

	for my $case (@CASES) {
		my ($name, $ref) = @{$case};

		my @warnings;
		local $SIG{__WARN__} = sub { push @warnings, @_ };

		my $result;
		lives_ok { $result = App::makefilepl2cpanfile::parse_prereqs($ref) }
			"parse_prereqs($name) does not die";

		isa_ok $result, 'HASH',  "$name returns a hashref";
		is scalar @warnings, 0,  "$name produces no warnings";
	}
};

subtest 'parse_prereqs: content with null bytes does not crash' => sub {
	# A null byte inside a module name is not a valid CPAN name but must not
	# crash the regex engine or emit warnings.
	Readonly my $CONTENT_WITH_NULL =>
		"PREREQ_PM => { 'Module\x00Name' => 0 },";

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $result;
	lives_ok {
		$result = App::makefilepl2cpanfile::parse_prereqs($CONTENT_WITH_NULL)
	} 'null bytes in content do not crash';

	isa_ok $result, 'HASH', 'returns a hashref for null-byte content';
	is scalar @warnings, 0,  'no warnings for null-byte content';
};

subtest 'parse_prereqs: deeply nested braces (5 levels) do not crash' => sub {
	# The parser supports up to 4 levels of brace nesting.  Content at the
	# 5th level must be silently skipped, not cause a crash or catastrophic
	# backtracking.  Strategy: build a module entry where the value is 5
	# levels deep and confirm the function returns without hanging.
	Readonly my $CONTENT_5_DEEP =>
		"PREREQ_PM => { 'Level1' => { a => { b => { c => { d => 0 } } } } },";

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $result;
	lives_ok {
		$result = App::makefilepl2cpanfile::parse_prereqs($CONTENT_5_DEEP)
	} '5-level brace nesting does not crash';

	isa_ok $result, 'HASH', 'returns a hashref with 5-level nesting';
	is scalar @warnings, 0,  'no warnings for 5-level nested content';

	diag 'Result: ' . join(', ', map { "phase=$_" } keys %{$result})
		if $ENV{TEST_VERBOSE};
};

subtest 'parse_prereqs: unclosed brace block does not crash or hang' => sub {
	# An unclosed outer brace means the regex cannot find a closing '}'.
	# The engine must fail the match cleanly and the function must return {}.
	Readonly my $UNCLOSED => "PREREQ_PM => { 'Module' => 0";    # missing }

	my $result;
	lives_ok {
		$result = App::makefilepl2cpanfile::parse_prereqs($UNCLOSED)
	} 'unclosed brace does not crash';

	isa_ok $result, 'HASH', 'returns a hashref for unclosed brace input';
	is scalar keys %{$result}, 0, 'result is empty when outer brace is unclosed';
};

subtest 'parse_prereqs: empty PREREQ_PM block returns no modules' => sub {
	# An explicit empty hash is valid Makefile.PL; no dependencies must appear.
	my $result = App::makefilepl2cpanfile::parse_prereqs(
		"PREREQ_PM => {},\n"
	);
	isa_ok $result, 'HASH', 'returns hashref for empty block';
	ok !exists $result->{runtime}, 'no runtime phase for empty PREREQ_PM';
};

subtest 'parse_prereqs: multiple PREREQ_PM blocks — first-occurrence wins' => sub {
	# When PREREQ_PM appears more than once (unusual but legal in generated
	# Makefile.PL), the first version string for a given module must survive;
	# a later block must not overwrite it.
	Readonly my $DOUBLE_BLOCK => <<'END';
PREREQ_PM => {
    'Moo' => '1.00',
},
PREREQ_PM => {
    'Moo' => '2.00',
},
END

	my $result = App::makefilepl2cpanfile::parse_prereqs($DOUBLE_BLOCK);
	is $result->{runtime}{requires}{'Moo'}{version}, '1.00',
		'first PREREQ_PM block wins for duplicate module';
};

subtest 'parse_prereqs: module name with Perl regex metacharacters' => sub {
	# Module names may not normally contain metacharacters, but the parser
	# must not crash.  The [^'"]+ capture class is safe for these characters.
	Readonly my $META_CONTENT => "PREREQ_PM => { 'Foo.Bar+Baz*Quux' => 0 },";

	my $result;
	lives_ok {
		$result = App::makefilepl2cpanfile::parse_prereqs($META_CONTENT)
	} 'module name with regex metacharacters does not crash';

	isa_ok $result, 'HASH', 'returns a hashref';
	diag 'Captured modules: ' . join(', ', keys %{ $result->{runtime}{requires} // {} })
		if $ENV{TEST_VERBOSE};
};

subtest 'parse_prereqs: version string edge cases for _has_version' => sub {
	# These edge cases test _has_version's numeric/non-numeric classification
	# and the convention that numeric zero means "any version" (no constraint).

	# "0.0" is numerically zero — no version constraint should be emitted.
	ok !App::makefilepl2cpanfile::_has_version('0.0'),
		'"0.0" classified as no version constraint (numeric zero)';

	# "0e0" is scientific-notation zero — still zero.
	ok !App::makefilepl2cpanfile::_has_version('0e0'),
		'"0e0" classified as no version constraint (scientific zero)';

	# "-0" is negative zero — numerically equal to positive zero.
	ok !App::makefilepl2cpanfile::_has_version('-0'),
		'"-0" classified as no version constraint (negative zero)';

	# "-1" is non-zero; unusual but constitutes a real version constraint.
	ok  App::makefilepl2cpanfile::_has_version('-1'),
		'"-1" classified as a real constraint (non-zero)';

	# " 1" has a leading space; looks_like_number returns true, value is 1.
	ok  App::makefilepl2cpanfile::_has_version(' 1'),
		'" 1" (leading space) classified as a real constraint';

	# "v1.2.3" is not a plain decimal number; treated as a real constraint.
	ok  App::makefilepl2cpanfile::_has_version('v1.2.3'),
		'"v1.2.3" (non-numeric) classified as a real constraint';

	diag '_has_version edge-case classifications all correct' if $ENV{TEST_VERBOSE};
};

subtest 'parse_prereqs: PREREQ_PM as variable reference — documented limitation' => sub {
	# When PREREQ_PM => $var (no literal brace block), the regex cannot match.
	# Strategy: verify the function silently returns {} with no warnings.
	Readonly my $DYNAMIC_DEPS =>
		"my \$deps = { 'Module' => 0 };\nWriteMakefile(PREREQ_PM => \$deps);\n";

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $result = App::makefilepl2cpanfile::parse_prereqs($DYNAMIC_DEPS);

	isa_ok $result, 'HASH', 'returns hashref for variable PREREQ_PM';
	ok !exists $result->{runtime},
		'no runtime phase (dynamic deps are a documented limitation)';
	is scalar @warnings, 0, 'no warnings for variable PREREQ_PM';
};

subtest 'parse_prereqs: list context returns a single hashref (not exploded)' => sub {
	# The POD says Returns: HashRef.  In list context the function must not
	# accidentally expand into a multi-element list.
	my @result = App::makefilepl2cpanfile::parse_prereqs(
		"PREREQ_PM => { 'Carp' => 0 },"
	);
	is scalar @result, 1,     'list context: exactly one element returned';
	isa_ok $result[0], 'HASH','the single element is a hashref';
};

# -----------------------------------------------------------------------
# SECTION 2: generate — hostile path and argument inputs
# -----------------------------------------------------------------------

subtest 'generate: makefile => undef defaults to Makefile.PL, croaks when absent' => sub {
	# undef is passed through the '// Makefile.PL' default, so the effective
	# path becomes 'Makefile.PL' in cwd.  In a directory without that file
	# the Cannot-read guard fires.
	my $g       = empty_home();
	my $workdir = tempdir(CLEANUP => 1);
	my $orig    = Path::Tiny->cwd;
	chdir $workdir;

	throws_ok {
		App::makefilepl2cpanfile::generate(makefile => undef)
	} qr/Cannot read 'Makefile\.PL'/, 'undef defaults to Makefile.PL, then croaks when absent';

	chdir "$orig";
};

subtest 'generate: empty string makefile path croaks' => sub {
	my $g = empty_home();
	throws_ok {
		App::makefilepl2cpanfile::generate(makefile => '')
	} qr/Cannot read/, 'empty-string makefile path causes croak';
};

subtest 'generate: /dev/null is not a regular file — must croak' => sub {
	# On POSIX systems -f '/dev/null' is false (character device, not a file).
	# The Cannot-read guard must fire before any slurp attempt.
	my $g = empty_home();
	throws_ok {
		App::makefilepl2cpanfile::generate(makefile => '/dev/null')
	} qr/Cannot read '\/dev\/null'/, '/dev/null causes croak';
};

subtest 'generate: path is a directory — must croak' => sub {
	my $g   = empty_home();
	my $dir = tempdir(CLEANUP => 1);
	throws_ok {
		App::makefilepl2cpanfile::generate(makefile => $dir)
	} qr/Cannot read/, 'directory path causes croak';
};

subtest 'generate: empty Makefile.PL returns header-only output without crashing' => sub {
	# A valid but content-free Makefile.PL must produce at least the generator
	# comment header and a single trailing newline.
	my $g  = empty_home();
	my $mf = make_mf('');    # completely empty file

	my $out;
	lives_ok {
		$out = App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 0,
		)
	} 'empty Makefile.PL does not crash';

	like   $out, qr/# Generated from Makefile\.PL/, 'header comment present';
	like   $out, qr/\n$/,                           'output ends with newline';
	unlike $out, qr/requires/,    'no requires for empty Makefile.PL';
	unlike $out, qr/on 'develop'/, 'no develop block for empty Makefile.PL';

	diag "Output:\n$out" if $ENV{TEST_VERBOSE};
};

subtest 'generate: no arguments in a directory without Makefile.PL — must croak' => sub {
	# With no arguments generate() defaults to 'Makefile.PL' in cwd.
	# In a directory that has no such file the guard must croak.
	my $g       = empty_home();
	my $workdir = tempdir(CLEANUP => 1);
	my $orig    = Path::Tiny->cwd;
	chdir $workdir;

	throws_ok {
		App::makefilepl2cpanfile::generate()
	} qr/Cannot read 'Makefile\.PL'/, 'no args + no Makefile.PL = croak';

	chdir "$orig";
};

subtest 'generate: existing => undef treated as empty string' => sub {
	# undef for 'existing' is equivalent to omitting the key; the develop
	# block should behave identically in both cases.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	my ($out_undef, $out_omit);
	lives_ok {
		$out_undef = App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			existing     => undef,
			with_develop => 0,
		);
		$out_omit = App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 0,
		);
	} 'existing => undef does not crash';

	is $out_undef, $out_omit,
		'existing => undef produces the same output as omitting existing';
};

subtest 'generate: existing develop block with }; inside comment — no truncation (BUG 2)' => sub {
	# BUG 2 (fixed): the old /s-only regex stopped at the first '};' anywhere
	# in the text, including inside an inline comment, silently dropping module
	# entries that followed the comment.
	# Strategy: place '};' inside a comment on a non-terminal line, then
	# confirm that a module declared AFTER the comment appears in the output.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	my $existing = "on 'develop' => sub {\n"
		. "    requires 'First::Tool';\n"
		. "    # Old Makefile syntax once used: };\n"    # '}; ' in comment
		. "    requires 'Second::Tool';\n"
		. "};\n";

	my $out = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		existing     => $existing,
		with_develop => 0,
	);

	diag "Output:\n$out" if $ENV{TEST_VERBOSE};

	like $out, qr/First::Tool/,
		'First::Tool present (before the commented }; )';
	like $out, qr/Second::Tool/,
		'Second::Tool present (after the commented }; ) — truncation bug fixed';
};

subtest 'generate: with_develop => "" (falsy) suppresses develop block' => sub {
	# An empty string is defined, bypasses '// 1', and is falsy.
	# The develop block must not appear in the output.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	my $out = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		with_develop => '',
	);

	unlike $out, qr/on 'develop' => sub/,
		"with_develop => '' (falsy) suppresses the develop block";

	diag "Output:\n$out" if $ENV{TEST_VERBOSE};
};

subtest "generate: with_develop => 'yes' (truthy string) injects develop block" => sub {
	# Any truthy value must activate the develop injection path.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	my $out = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		with_develop => 'yes',
	);

	like $out, qr/on 'develop' => sub/,
		"with_develop => 'yes' (truthy) injects develop block";

	diag "Output:\n$out" if $ENV{TEST_VERBOSE};
};

subtest 'generate: extra unknown keys in argument hash are silently ignored' => sub {
	# Callers sometimes pass extra context metadata; the function must not die.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	my $out;
	lives_ok {
		$out = App::makefilepl2cpanfile::generate(
			makefile      => "$mf",
			with_develop  => 0,
			unknown_key   => 'should be ignored',
			another_extra => 42,
		);
	} 'extra unknown keys do not cause a crash';

	like $out, qr/Carp/, 'normal output produced despite extra keys';
};

subtest 'generate: list context returns exactly one Str element' => sub {
	# The POD says Returns: Str.  Calling in list context must yield a
	# single-element list, not an accidentally exploded multi-value return.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	my @result = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		with_develop => 0,
	);

	is   scalar @result, 1,    'list context: exactly one element returned';
	ok   !ref $result[0],      'the element is a plain Str (not a reference)';
	like $result[0], qr/\n$/, 'the value ends with a newline';
};

# -----------------------------------------------------------------------
# SECTION 3: Security — module name content via YAML config
# -----------------------------------------------------------------------

subtest 'security: YAML config module name with single quote' => sub {
	# A module name containing a single quote causes _fmt_dep to embed an
	# unmatched quote in the output line:  requires 'Bad'Quote';
	# This documents the behaviour for user-controlled config; it is NOT
	# a remote-code-execution vector since the user controls their own
	# ~/.config file.
	my $g  = home_with_config( { develop => { "Bad'Quote" => 0 } } );
	my $mf = make_mf($MF_SIMPLE);

	my $out;
	lives_ok {
		$out = App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 1,
		);
	} 'single-quote module name does not crash generate()';

	like $out, qr/Bad/, 'partial module name appears in output';

	diag "Output with bad module name:\n$out" if $ENV{TEST_VERBOSE};
};

subtest 'security: Makefile.PL module names cannot carry quote characters (injection safe)' => sub {
	# Module names from PREREQ_PM are captured via [^'"]+, which physically
	# prevents single or double quotes from entering the name.  This test
	# verifies that a Makefile.PL with a double-quoted key whose value includes
	# a single quote does NOT inject unmatched quotes into the cpanfile output.
	#
	# Given:  "Foo'Bar" => 0   (outer delimiter: double-quote)
	# [^'"]+ stops at the embedded ', so only "Foo" is captured.
	# The output must have balanced single quotes.
	my $g  = empty_home();
	my $mf = make_mf(
		"WriteMakefile(PREREQ_PM => { \"Foo'Bar\" => 0 });\n"
	);

	my $out = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		with_develop => 0,
	);

	my $single_quote_count = () = $out =~ /'/g;
	is $single_quote_count % 2, 0,
		'all single quotes in output are balanced (no quote injection from Makefile.PL)';

	diag "Quote count: $single_quote_count\nOutput:\n$out" if $ENV{TEST_VERBOSE};
};

subtest 'security: existing cpanfile module names cannot carry quotes (injection safe)' => sub {
	# Same property as above but for module names read back from an existing
	# cpanfile develop block.  The merge regex also uses [^'"]+ to capture
	# module names, so embedded quotes are impossible.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	# The module name between the outer quotes is "Safe::Module"; the
	# surrounding requires '...' is what gets parsed.  We craft an existing
	# block with no embedded quotes — just verify balanced output.
	Readonly my $EXISTING => <<'END';
on 'develop' => sub {
    requires 'Safe::Module';
};
END

	my $out = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		existing     => $EXISTING,
		with_develop => 0,
	);

	my $count = () = $out =~ /'/g;
	is $count % 2, 0, 'quotes are balanced when merging existing develop block';
	like $out, qr/Safe::Module/, 'existing module preserved in output';
};

# -----------------------------------------------------------------------
# SECTION 4: State isolation — defensive copies and no shared state
# -----------------------------------------------------------------------

subtest 'parse_prereqs: mutating the returned hashref does not affect next call' => sub {
	# The returned hashref must be a fresh allocation per call; mutating it
	# must not contaminate subsequent calls (no shared module-level state).
	my $r1 = App::makefilepl2cpanfile::parse_prereqs(
		"PREREQ_PM => { 'Carp' => 0 },"
	);

	# Aggressively mutate the returned structure.
	$r1->{runtime}{requires}{'Injected::Evil'} =
		{ version => 99, comment => 'injected' };
	delete $r1->{runtime}{requires}{'Carp'};

	my $r2 = App::makefilepl2cpanfile::parse_prereqs(
		"PREREQ_PM => { 'Carp' => 0 },"
	);

	ok  exists $r2->{runtime}{requires}{'Carp'},
		'Carp still present in second call after first-call mutation';
	ok !exists $r2->{runtime}{requires}{'Injected::Evil'},
		'Injected key absent from second call — no shared state';
};

subtest 'generate: successive calls with different with_develop produce independent outputs' => sub {
	# Call generate() three times in sequence: no-develop, with-develop,
	# no-develop again.  The third output must match the first exactly,
	# proving that the second call left no residual develop state.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	my $no_dev = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		with_develop => 0,
	);
	my $with_dev = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		with_develop => 1,
	);
	my $no_dev_again = App::makefilepl2cpanfile::generate(
		makefile     => "$mf",
		with_develop => 0,
	);

	unlike $no_dev,      qr/on 'develop' => sub/, 'first call: no develop block';
	like   $with_dev,    qr/on 'develop' => sub/, 'second call: develop block present';
	is     $no_dev_again, $no_dev,
		'third call matches first — no state bleed from second call';
};

done_testing;
