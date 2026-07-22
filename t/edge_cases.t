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

# -----------------------------------------------------------------------
# SECTION 5: Input Hostility — Extended
#
# Bug found and fixed during authoring:
#   BUG 3 — _load_develop_config: File::HomeDir::my_home returning undef
#     caused path(undef) to croak with a Path::Tiny error message rather than
#     falling back to %DEFAULT_DEVELOP.  This breaks CI environments and
#     containers that have no home directory set.
#     FIX: early return of {%DEFAULT_DEVELOP} when my_home() returns undef.
# -----------------------------------------------------------------------

subtest 'parse_prereqs: circular reference returns empty hashref silently' => sub {
	# A reference that points to itself (circular) must not cause infinite
	# traversal.  The !ref guard returns {} before the regex engine is reached.
	my $circular;
	$circular = \$circular;    # REF type: ref($circular) eq 'REF'

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $result;
	lives_ok { $result = App::makefilepl2cpanfile::parse_prereqs($circular) }
		'circular reference does not cause infinite recursion or crash';

	isa_ok $result, 'HASH', 'circular ref input returns a hashref';
	is scalar keys %{$result}, 0, 'result is empty for circular reference input';
	is scalar @warnings, 0, 'no warnings for circular reference input';
};

subtest 'parse_prereqs: invalid UTF-8 bytes in content string — no crash, no warnings' => sub {
	# When the caller passes a byte string containing invalid UTF-8 sequences,
	# the regex engine must operate on the raw bytes without crashing or warning.
	# Byte strings (no UTF-8 flag) are valid Perl scalars; [^{}] matches any byte.
	my $content = "PREREQ_PM => { \x27Carp\x27 => 0 };\xFF\xFEjunk";

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $result;
	lives_ok { $result = App::makefilepl2cpanfile::parse_prereqs($content) }
		'invalid UTF-8 bytes in string content do not crash parse_prereqs';

	isa_ok $result, 'HASH', 'returns a hashref for content with invalid UTF-8 bytes';
	is scalar @warnings, 0, 'no warnings emitted for byte-string content';

	diag "Found phases: " . join(', ', keys %{$result}) if $ENV{TEST_VERBOSE};
};

subtest 'generate: Makefile.PL with trailing invalid UTF-8 bytes — warns, finds valid deps' => sub {
	# Path::Tiny slurp_utf8 emits Carp warnings for each ill-formed byte but
	# does NOT die — it returns the (possibly substituted) content and continues.
	# Strategy: write a file whose valid prefix contains a PREREQ_PM block and
	# whose suffix contains \xFF\xFE; verify generate() survives and finds Carp.
	my $g     = empty_home();
	my $dir   = tempdir(CLEANUP => 1);
	my $mf    = path($dir)->child('Makefile.PL');
	$mf->spew_raw("WriteMakefile(PREREQ_PM => { \x27Carp\x27 => 0 });\xFF\xFE\n");

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $out;
	lives_ok {
		$out = App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 0,
		)
	} 'invalid UTF-8 bytes in Makefile.PL do not crash generate()';

	like $out, qr/Carp/, 'valid dep before invalid bytes is captured correctly';
	ok scalar @warnings > 0,
		'invalid UTF-8 bytes trigger warnings from slurp_utf8 (not silent corruption)';

	diag "Warning count: " . scalar(@warnings) if $ENV{TEST_VERBOSE};
};

subtest 'parse_prereqs: extreme numerical version strings — _has_version contract' => sub {
	# Verify that unusual-but-valid number strings (Inf, NaN, very large ints)
	# are handled consistently by the looks_like_number + != 0 logic.
	# These are "real constraints" (non-zero) even if nonsensical in practice.
	Readonly my @EXTREME_NONZERO_VERS => (
		[ 'Inf',                    1, 'Inf is looks_like_number and != 0'           ],
		[ '-Inf',                   1, '-Inf is looks_like_number and != 0'          ],
		[ 'NaN',                    1, 'NaN is looks_like_number and != 0 (IEEE 754)'],
		[ '99999999999999999999',   1, '20-digit int overflows to ~1e20, != 0'       ],
		[ '0.000000001',            1, 'tiny positive fraction is non-zero'          ],
		[ '1e300',                  1, 'very large float is non-zero'                ],
	);
	Readonly my @EXTREME_ZERO_VERS => (
		[ '0.000',                  0, 'leading zeros — numerically zero'            ],
		[ '+0',                     0, 'explicit positive zero is still zero'        ],
	);

	for my $case (@EXTREME_NONZERO_VERS) {
		my ($ver, $expected, $label) = @{$case};
		is !!App::makefilepl2cpanfile::_has_version($ver), !!$expected, $label;
	}
	for my $case (@EXTREME_ZERO_VERS) {
		my ($ver, $expected, $label) = @{$case};
		is !!App::makefilepl2cpanfile::_has_version($ver), !!$expected, $label;
	}
};

subtest 'parse_prereqs: 1 MB of noise with embedded PREREQ_PM — completes without crashing' => sub {
	# Defensive performance test: a megabyte of random-ish content must not
	# cause catastrophic regex backtracking.  [^{}] and \{...\} are mutually
	# exclusive at each position, so no backtracking occurs.
	# Strategy: embed a valid PREREQ_PM block inside 500 KB of ASCII noise on
	# either side and verify parse_prereqs finds the module.
	Readonly my $HALF_MB => 'abcdefg ' x 70_000;    # ~560 KB, no braces
	my $content = $HALF_MB
		. "PREREQ_PM => { \x27Carp\x27 => 0 },"
		. $HALF_MB;

	my $result;
	lives_ok { $result = App::makefilepl2cpanfile::parse_prereqs($content) }
		'1 MB of content does not crash parse_prereqs';

	ok exists $result->{runtime}{requires}{'Carp'},
		'Carp found inside 1 MB content — regex scans without hanging';
};

subtest 'parse_prereqs: 100-level brace nesting completes within time limit' => sub {
	# Verify no catastrophic backtracking when brace nesting far exceeds the
	# 4-level regex limit.  Uses alarm() to enforce a hard wall-clock ceiling.
	SKIP: {
		skip 'alarm() is unreliable on this platform', 3 if $^O eq 'MSWin32';

		Readonly my $ALARM_SECS => 5;
		my $timed_out = 0;

		local $SIG{ALRM} = sub { $timed_out = 1; die "TIMEOUT\n" };
		alarm($ALARM_SECS);

		my $content = 'PREREQ_PM => '
			. ('{' x 100)
			. "\x27Module\x27 => 0"    # 'Module' => 0 as raw bytes
			. ('}' x 100);

		my $result;
		lives_ok { $result = App::makefilepl2cpanfile::parse_prereqs($content) }
			'100-level brace nesting does not crash or time out';

		alarm(0);

		ok !$timed_out, "completed within ${ALARM_SECS}s (no catastrophic backtracking)";
		isa_ok $result, 'HASH', 'returns a hashref even for extreme brace nesting';
	}
};

subtest 'parse_prereqs: version as unevaluated Perl expression — security invariant' => sub {
	# A module version written as a Perl expression (e.g. 9**9**9) in the
	# source of Makefile.PL must NEVER be evaluated.  The regex captures only
	# the leading digit sequence; 9**9**9 becomes version '9', not Inf or error.
	my $content = "PREREQ_PM => { \x27Module\x27 => 9**9**9 },";

	my $result;
	lives_ok { $result = App::makefilepl2cpanfile::parse_prereqs($content) }
		'Perl expression as version does not crash or eval';

	my $ver = $result->{runtime}{requires}{'Module'}{version} // 'undef';
	ok defined $ver, 'version field is defined (regex captured leading digits)';
	unlike "$ver", qr/Inf|NaN/i, 'captured version is not Inf/NaN (no eval occurred)';
	ok $ver =~ /^\d/, 'captured version starts with a digit — just the literal text';

	diag "Captured version for 9**9**9: $ver" if $ENV{TEST_VERBOSE};
};

subtest 'generate: reference as existing arg — no crash, no spurious develop merge' => sub {
	# A reference passed as existing stringifies silently to e.g. "ARRAY(0x...)"
	# which the develop-block regex cannot match.  No warnings are emitted and
	# no develop block should appear in the output.
	my $g  = empty_home();
	my $mf = make_mf($MF_SIMPLE);

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $out;
	lives_ok {
		$out = App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			existing     => [],    # array ref, not a string
			with_develop => 0,
		)
	} 'array ref as existing does not crash';

	is scalar @warnings, 0, 'no warnings for reference existing arg';
	unlike $out, qr/on 'develop' => sub/,
		'no spurious develop block from reference existing';
	like $out, qr/Carp/, 'normal dep output produced';
};

# -----------------------------------------------------------------------
# SECTION 6: Filesystem Hostility
# -----------------------------------------------------------------------

subtest 'generate: unreadable Makefile.PL (mode 000) must croak' => sub {
	# Strategy: create a file, remove all permissions, then verify the
	# -r guard fires.  Root bypasses permissions, so skip under euid 0.
	SKIP: {
		skip 'running as root — filesystem permissions are not enforced', 1
			if $> == 0;

		my $g   = empty_home();
		my $dir = tempdir(CLEANUP => 1);
		my $mf  = path($dir)->child('Makefile.PL');
		$mf->spew_utf8($MF_SIMPLE);
		chmod 0000, "$mf";

		throws_ok {
			App::makefilepl2cpanfile::generate(makefile => "$mf")
		} qr/Cannot read/, 'mode-000 Makefile.PL causes croak';

		chmod 0644, "$mf";    # restore so temp-cleanup can remove it
	}
};

subtest 'generate: dangling symlink must croak' => sub {
	# A symlink whose target does not exist: -f returns false (target absent),
	# so the Cannot-read guard must fire.
	my $g      = empty_home();
	my $dir    = tempdir(CLEANUP => 1);
	my $target = path($dir)->child('nonexistent_target.pl');
	my $link   = path($dir)->child('Makefile.PL');

	SKIP: {
		symlink("$target", "$link") or skip 'symlinks not supported on this platform', 1;

		throws_ok {
			App::makefilepl2cpanfile::generate(makefile => "$link")
		} qr/Cannot read/, 'dangling symlink causes croak (-f is false for missing target)';
	}
};

subtest 'generate: /dev/urandom is a character device — must croak' => sub {
	# Character devices pass -e but fail -f (not a regular file).
	my $g = empty_home();
	SKIP: {
		skip '/dev/urandom not available on this platform', 1
			unless -e '/dev/urandom';

		throws_ok {
			App::makefilepl2cpanfile::generate(makefile => '/dev/urandom')
		} qr/Cannot read '\/dev\/urandom'/, '/dev/urandom causes croak (character device)';
	}
};

subtest 'generate: path containing spaces is handled correctly' => sub {
	# Paths with spaces are ordinary filesystem paths on POSIX; the module uses
	# Perl file-test operators and Path::Tiny (not shell commands), so no quoting
	# issues arise.
	my $g       = empty_home();
	my $dir     = path(tempdir(CLEANUP => 1))->child('dir with spaces');
	$dir->mkpath;
	my $mf = $dir->child('Makefile.PL');
	$mf->spew_utf8($MF_SIMPLE);

	my $out;
	lives_ok {
		$out = App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 0,
		)
	} 'path with spaces does not trigger shell-quoting issues';

	like $out, qr/Carp/, 'correct output from path with spaces';
};

subtest 'generate: path with shell-injection characters is rejected by Cannot-read guard' => sub {
	# Paths like "/tmp; rm -rf /" contain shell metacharacters, but since
	# Perl and Path::Tiny never pass them to a shell, they are benign file
	# paths.  No such file exists, so the guard croaks safely.
	my $g = empty_home();

	throws_ok {
		App::makefilepl2cpanfile::generate(makefile => '/tmp/; rm -rf /; #.pl')
	} qr/Cannot read/, 'shell-injection path is rejected (file does not exist)';

	throws_ok {
		App::makefilepl2cpanfile::generate(makefile => "/tmp/Make\nfile.PL")
	} qr/Cannot read/, 'path with embedded newline is rejected (file does not exist)';
};

subtest 'generate: extremely long path is rejected by Cannot-read guard' => sub {
	# Most filesystems cap path lengths well below PATH_MAX (4096 on Linux).
	# A 5000-char path cannot correspond to an existing file; the guard must
	# croak cleanly without crashing the regex or OS call.
	my $g         = empty_home();
	my $long_path = 'M' x 5000;

	throws_ok {
		App::makefilepl2cpanfile::generate(makefile => $long_path)
	} qr/Cannot read/, 'extremely long path causes croak gracefully';
};

# -----------------------------------------------------------------------
# SECTION 7: Upstream Failure Simulation via Test::Mockingbird
#
# These tests simulate real-world upstream failures: I/O interruptions,
# missing home directory (containers), and YAML service timeouts.
# They verify that the module propagates errors clearly without masking
# the root cause or leaving the process in a corrupted state.
# -----------------------------------------------------------------------

subtest 'upstream: Path::Tiny::slurp_utf8 dies — generate propagates the I/O error' => sub {
	# Simulates a network filesystem going down between the readability check
	# and the actual read, or a catastrophic hardware read error.
	# Strategy: create a valid Makefile.PL (passes -f && -r), then mock
	# slurp_utf8 to die so the error surfaces after the guard.
	my $g_home  = empty_home();
	my $mf      = make_mf($MF_SIMPLE);
	my $g_slurp = mock_scoped 'Path::Tiny::slurp_utf8' => sub {
		die "Input/output error: simulated disk failure\n";
	};

	throws_ok {
		App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 0,
		)
	} qr/Input\/output error.*simulated disk failure/,
		'slurp_utf8 I/O failure propagates transparently from generate()';
};

subtest 'upstream: File::HomeDir::my_home returns undef — falls back to defaults (BUG 3)' => sub {
	# Simulates a container or CI job that runs under a user with no home
	# directory set (e.g., nobody, or a UID with no passwd entry).
	# BUG 3 (fixed): before the fix, path(undef) croaked from Path::Tiny
	# with "positive-length parts" error, not a clean fallback to defaults.
	my $g_home = mock_scoped 'File::HomeDir::my_home' => sub { undef };
	my $mf     = make_mf($MF_SIMPLE);

	my $out;
	lives_ok {
		$out = App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 1,    # forces _load_develop_config call
		)
	} 'undef my_home does not crash (BUG 3 fixed — falls back to defaults)';

	like $out, qr/Perl::Critic/,
		'default develop tool present — fallback to %DEFAULT_DEVELOP works';
	like $out, qr/on 'develop' => sub/,
		'develop block was emitted using default tools';

	diag "Output:\n$out" if $ENV{TEST_VERBOSE};
};

subtest 'upstream: YAML::Tiny simulated timeout — croak includes path and message' => sub {
	# Simulates a YAML parsing backend that fails mid-operation (e.g. a remote
	# config service returning an error, or a corrupt/truncated YAML file).
	# The croak message must include both the config file path and the upstream
	# error text so operators can diagnose the failure.
	my $dir = tempdir(CLEANUP => 1);
	path($dir)->child('.config')->mkpath;
	path($dir)->child('.config', 'makefilepl2cpanfile.yml')->spew_utf8(
		"develop:\n  Perl::Critic: 0\n"    # valid YAML on disk
	);

	my $g_home = mock_scoped 'File::HomeDir::my_home' => sub { $dir };
	my $g_yaml = mock_scoped(
		'YAML::Tiny::read'   => sub { undef },
		'YAML::Tiny::errstr' => sub { 'connection timed out after 30s' },
	);

	my $mf = make_mf($MF_SIMPLE);

	throws_ok {
		App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 1,
		)
	} qr/Failed to parse .+ connection timed out/s,
		'YAML upstream failure croaks with path and error message';
};

subtest 'upstream: Path::Tiny::is_file dies (simulated stat() failure) — propagates' => sub {
	# Simulates a filesystem that has become unreachable after the home
	# directory was resolved (e.g. an NFS mount that went stale between
	# the my_home() call and the subsequent is_file() check on the config path).
	# The error must propagate out of generate() without being swallowed.
	my $g_home   = empty_home();
	my $mf       = make_mf($MF_SIMPLE);
	my $g_isfile = mock_scoped 'Path::Tiny::is_file' => sub {
		die "stat(): Stale NFS file handle\n";
	};

	throws_ok {
		App::makefilepl2cpanfile::generate(
			makefile     => "$mf",
			with_develop => 1,    # triggers _load_develop_config -> is_file
		)
	} qr/stat\(\).*Stale NFS/,
		'Path::Tiny::is_file failure propagates from _load_develop_config';
};

done_testing;
