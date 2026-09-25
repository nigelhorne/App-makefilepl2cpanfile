package App::makefilepl2cpanfile;

use strict;
use warnings;
use autodie qw(:all);
use Carp qw(croak carp);
use Readonly;
use List::Util    qw(any);
use Path::Tiny;
use Params::Get;
use YAML::Tiny;
use File::HomeDir;
use Fcntl ();

=encoding utf-8

=head1 NAME

App::makefilepl2cpanfile - Convert Makefile.PL to a cpanfile automatically

=head1 VERSION

This document describes App::makefilepl2cpanfile version 0.04.

=cut

our $VERSION = '0.04';

# -----------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------

# Default author/developer tools added to the 'develop' phase when
# with_develop is true and no user config file overrides them.
Readonly my %DEFAULT_DEVELOP => (
	'Devel::Cover'        => 0,
	'Perl::Critic'        => 0,
	'Test::Pod'           => 0,
	'Test::Pod::Coverage' => 0,
);

# Maps each Makefile.PL simple-dependency key to its cpanfile phase name.
# All of these are treated as 'requires' relationships.
Readonly my %PHASE_MAP => (
	BUILD_REQUIRES     => 'build',
	CONFIGURE_REQUIRES => 'configure',
	PREREQ_PM          => 'runtime',
	TEST_REQUIRES      => 'test',
);

# Valid cpanfile phase names recognised inside 'prereqs => { ... }' blocks.
Readonly my %VALID_PHASE => map { $_ => 1 }
	qw(runtime configure build test develop);

# Valid cpanfile relationship keywords inside each phase block.
Readonly my %VALID_REL => map { $_ => 1 }
	qw(requires recommends suggests);

# Canonical emit order for non-runtime phases (runtime is special-cased at
# the top level per cpanfile convention).
Readonly my @PHASE_ORDER => qw(configure build test develop);

# Within each phase block, emit relationships in this order.
Readonly my @REL_ORDER => qw(requires recommends suggests);

# First line of every generated cpanfile.
Readonly my $HEADER => '# Generated from Makefile.PL using makefilepl2cpanfile';

# A CPAN module name: ASCII only (as PAUSE requires), so look-alike
# characters from other scripts cannot smuggle in a different module.
# Possessive quantifiers: no backtracking on hostile input.
Readonly my $MODULE_NAME_RE => qr/\A[A-Za-z_]\w*+(?:::\w++)*+\z/a;

# The whole value after '=>': a single- or double-quoted string, or a bare
# token.  The complete token is captured so that it is validated as a
# unit - capturing only a numeric prefix would turn '1e3' into '1'.
Readonly my $VALUE_TOKEN_RE => qr/(?:'([^'\n]*+)'|"([^"\n]*+)"|([^\s,}#'"]++))/;

# Characters stripped from comments before they are written out: C0/C1
# controls other than TAB (a CR can visually overwrite a line) and the
# Unicode bidirectional controls used by "Trojan Source" (CVE-2021-42574)
# to make text display differently from how it is read.
Readonly my $UNSAFE_COMMENT_CHARS_RE =>
	qr/[\x00-\x08\x0A-\x1F\x7F-\x9F\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/;

=head1 SYNOPSIS

Create or refresh the F<cpanfile> of the project in the current directory:

	use App::makefilepl2cpanfile;
	use Path::Tiny;

	my $text = App::makefilepl2cpanfile::generate();
	path('cpanfile')->spew_utf8($text);

Keep the hand-written C<develop> section of an existing F<cpanfile>:

	my $old  = path('cpanfile')->slurp_utf8;
	my $text = App::makefilepl2cpanfile::generate(existing => $old);
	path('cpanfile')->spew_utf8($text);

Make a F<cpanfile> for another project, with no developer tools added.
The result is the same on every computer, which is useful in CI:

	my $text = App::makefilepl2cpanfile::generate({
		makefile     => '/path/to/other/project/Makefile.PL',
		with_develop => 0,
	});

List every dependency without making a F<cpanfile>:

	my $deps = App::makefilepl2cpanfile::parse_prereqs(
		path('Makefile.PL')->slurp_utf8
	);
	for my $phase (sort keys %{$deps}) {
		for my $rel (sort keys %{ $deps->{$phase} }) {
			for my $module (sort keys %{ $deps->{$phase}{$rel} }) {
				print "$phase $rel $module\n";
			}
		}
	}

Check in a test that the committed F<cpanfile> is up to date:

	use Test::More;
	is(
		App::makefilepl2cpanfile::generate(existing => path('cpanfile')->slurp_utf8),
		path('cpanfile')->slurp_utf8,
		'cpanfile matches Makefile.PL',
	);

From the command line (see L<makefilepl2cpanfile>):

	makefilepl2cpanfile              # write ./cpanfile
	makefilepl2cpanfile --dry-run    # print it instead
	makefilepl2cpanfile --diff       # show what would change

=head1 DESCRIPTION

A Perl distribution lists the modules it needs in its F<Makefile.PL>.
Many tools (for example C<cpanm --installdeps .> and CI systems) prefer
a F<cpanfile> instead.  This module reads a F<Makefile.PL> and writes the
same list in F<cpanfile> form, so you only keep the list in one place.

The F<Makefile.PL> is B<never run>.  It is read as plain text and
searched for the parts that list dependencies.  This makes the tool safe
to use on code you do not trust, but it also means that it cannot see
dependencies that are computed while the program runs (see
L</COMMON PITFALLS>).

=head2 What it reads

=over 4

=item * C<PREREQ_PM>, C<BUILD_REQUIRES>, C<TEST_REQUIRES> and
C<CONFIGURE_REQUIRES>.  These become C<requires> lines in the C<runtime>,
C<build>, C<test> and C<configure> phases.

=item * C<prereqs =E<gt> { PHASE =E<gt> { RELATIONSHIP =E<gt> { ... } } }>
blocks (the CPAN::Meta::Spec version 2 layout), wherever they appear -
also inside C<META_MERGE>.

=item * C<recommends =E<gt> { ... }> and C<suggests =E<gt> { ... }>
directly inside C<META_MERGE> (the older version 1 layout).  These become
C<recommends> and C<suggests> lines in the C<runtime> phase.

=item * C<MIN_PERL_VERSION>, which becomes C<requires 'perl', 'VERSION';>.

=item * A C<#> comment after an entry.  It is copied to the F<cpanfile>.

=back

=head2 What it writes

	# Generated from Makefile.PL using makefilepl2cpanfile

	requires 'perl', '5.010';

	requires 'Moo', '2.000';   # object system
	requires 'Try::Tiny';
	recommends 'JSON::MaybeXS';

	on 'test' => sub {
		requires 'Test::More', '0.98';
	};

	on 'develop' => sub {
		requires 'Perl::Critic';
	};

Runtime dependencies come first, without an C<on> block.  The other
phases follow in this order: C<configure>, C<build>, C<test>, C<develop>.
Inside each phase, C<requires> lines come first, then C<recommends>, then
C<suggests>, and the modules are in alphabetical order.  The same input
always gives exactly the same output.

=head1 CONFIGURATION

When C<with_develop> is true (the default), some developer tools are
added to the C<develop> phase.  By default these are L<Devel::Cover>,
L<Perl::Critic>, L<Test::Pod> and L<Test::Pod::Coverage>.

To choose your own list, create the file
F<~/.config/makefilepl2cpanfile.yml>:

	develop:
	  Perl::Critic: 0
	  Devel::Cover: 0
	  My::Extra::Tool: '1.00'

The number after each name is the minimum version; C<0> means "any
version".  Your list B<replaces> the default list; it is not added to it.
Names that are not valid module names, and versions that are not version
numbers, are ignored with a warning, so a mistake in this file can never
put unexpected code into your F<cpanfile>.

=head1 DATA STRUCTURE

C<parse_prereqs()> returns a hash reference with three levels:

	{
		PHASE => {
			RELATIONSHIP => {
				'Module::Name' => { version => '1.0', comment => 'why it is needed' },
			},
		},
	}

=over 4

=item * PHASE is one of C<runtime>, C<configure>, C<build>, C<test> or
C<develop>.

=item * RELATIONSHIP is one of C<requires>, C<recommends> or C<suggests>.

=item * C<version> is the minimum version exactly as it was written (for
example C<'1.60'> stays C<'1.60'>).  It is C<0> when there is no minimum.

=item * C<comment> is the text of the C<#> comment after the entry, or
C<undef> when there is none.

=back

A phase or relationship with no modules is not present at all.

=head1 ENCODING

=over 4

=item * B<The Makefile.PL file> is read as UTF-8.  Comments may contain
any printable Unicode text, including accented letters, emoji and
combining marks; they are copied to the output unchanged.  Control
characters (other than TAB) and Unicode direction-override characters
are removed from comments, so that the generated file cannot be made to
look different from what it really contains.  If the file is not valid UTF-8 you get a
warning and processing continues (see L</generate(%args)>).

=item * B<The returned cpanfile text> is a Perl character string.  Write
it with a UTF-8 output layer, for example C<path(...)-E<gt>spew_utf8> or
C<binmode $fh, ':encoding(UTF-8)'>.  Otherwise Perl warns
"Wide character in print" when a comment contains non-ASCII text.

=item * B<The existing argument> and B<the content argument of
parse_prereqs()> must be character strings: decode them first (for
example with C<slurp_utf8>).  Raw bytes work for plain ASCII, but a
non-ASCII comment would come back as separate bytes.

=item * B<Module names> must be plain ASCII (A-Z, a-z, 0-9, C<_> and
C<::>), as CPAN requires.  A name with any other character is ignored.
This also stops look-alike names, such as C<Test::More> written with a
Cyrillic letter.

=item * B<Version numbers> may use only the ASCII digits 0-9, C<.>,
C<_> and a leading C<v>, and must contain at least one digit.  The whole
value is checked: C<'1.0-TRIAL'> is not shortened to C<'1.0'>.  Anything
else is treated as "no minimum version".

=item * B<The YAML configuration file> is read as UTF-8; the same rules
for names and versions apply.

=item * B<File names> are passed to the operating system unchanged.
Names with spaces, non-ASCII letters or shell characters such as C<;>
and C<|> are safe: no shell is ever used.

=back

=head1 COMMON PITFALLS

=over 4

=item * B<Code in Makefile.PL is not run.>  Dependencies that are built
by code are not seen, for example C<PREREQ_PM =E<gt> \%deps> or a list
returned by a function.  Entries inside a condition, such as
C<$^O eq 'MSWin32' ? ('Win32' =E<gt> 0) : ()>, are seen but become
unconditional.  Write such dependencies as plain entries, or add them to
the F<cpanfile> another way.

=item * B<Only the develop section of an existing cpanfile is kept.>
Hand edits anywhere else (for example a C<feature> block or an extra
C<on 'test'> line) are lost when you regenerate.  Put hand-written
entries in C<on 'develop' =E<gt> sub { ... }>.

=item * B<Conditions inside the kept develop section are removed.>  An
C<if (...) { requires 'X' }> inside the develop block is carried over as
a plain C<requires 'X'>.  Comments in the develop block are not kept.

=item * B<Which entry wins.>  When the same module is listed twice in the
same phase and relationship, the first one wins.  The simple keys
(C<PREREQ_PM> and friends) are read before C<prereqs> blocks, and entries
from F<Makefile.PL> win over entries in the existing develop section.
The same module under two different relationships (for example
C<requires> and C<recommends>) is kept twice.

=item * B<The configuration file replaces the default tools.>  If you
list only C<My::Tool>, then C<Perl::Critic> and the others are no longer
added.  List them too if you want them.

=item * B<undef means "use the default".>  C<makefile =E<gt> undef> reads
F<Makefile.PL>; C<existing =E<gt> undef> is the same as C<''>; and
C<with_develop =E<gt> undef> means B<true>.  Use C<with_develop =E<gt> 0>
to turn developer tools off.

=item * B<parse_prereqs(undef) is silent.>  It returns an empty hash
reference with no warning, so a failed file read can look like "no
dependencies".  Check that the read worked before you call it.

=item * B<The output depends on who runs it.>  With C<with_develop> on,
the tool list comes from the home directory of the current user.  Use
C<with_develop =E<gt> 0> when every computer must produce the same file.

=item * B<generate() does not write any file.>  It returns the text.
Save it yourself (see L</SYNOPSIS>) or use the command-line tool.

=item * B<Relative paths> in C<makefile> are relative to the current
working directory, not to your script.

=item * B<Warnings are not errors.>  Problems such as invalid UTF-8 or a
bad configuration entry are reported with C<warn> (through L<Carp>) and
processing continues.  Catch them with C<$SIG{__WARN__}> if you need to
act on them.

=back

=head1 METHODS

=head2 generate(%args)

=head3 PURPOSE

Reads a F<Makefile.PL> and returns the text of a matching F<cpanfile>.
The F<Makefile.PL> is read as text and is never run.

=head3 ARGUMENTS

Give the arguments as a list of name/value pairs, or as one hash
reference.  All of them are optional.

=over 4

=item * C<makefile> - the path of the F<Makefile.PL> to read.  Default:
C<'Makefile.PL'> in the current directory.  Anything that turns into a
path when used as a string is accepted, such as a L<Path::Tiny> object.
A filehandle or another kind of reference is refused with
C<Cannot read>.

=item * C<existing> - the text of your current F<cpanfile>.  Default:
C<''> (none).  Only its C<on 'develop' =E<gt> sub { ... }> section is
used.  Every C<requires>, C<recommends> and C<suggests> line in that
section is copied to the new text, so your hand-written developer
dependencies are kept.  Lines that are commented out are not copied.
An entry whose name is not a valid module name is dropped.  An entry
whose version is not a version number is kept without a version, and
you get a warning.

=item * C<with_develop> - true or false.  Default: true.  When true, the
developer tools from the configuration file (see L</CONFIGURATION>), or
the default tools, are added to the C<develop> phase as C<requires>.  A
tool that is already in the develop phase, from the F<Makefile.PL> or
from C<existing>, is left exactly as it is.

=back

=head3 RETURNS

A string: the complete F<cpanfile>.  It always starts with the line
C<# Generated from Makefile.PL using makefilepl2cpanfile> and always ends
with exactly one newline.  The layout is described in
L</What it writes>.  A F<Makefile.PL> with no dependencies gives just
the first line.

=head3 SIDE EFFECTS

=over 4

=item * Reads the C<makefile> file.

=item * When C<with_develop> is true, reads
F<~/.config/makefilepl2cpanfile.yml> if it exists.

=item * Never writes, creates or deletes any file.

=item * May print warnings (see MESSAGES below).

=item * Does not change the caller's C<$@>, C<$!> or C<$_>.

=back

=head3 USAGE EXAMPLE

	use App::makefilepl2cpanfile;
	use Path::Tiny;

	my $cpanfile = path('cpanfile');
	my $text = App::makefilepl2cpanfile::generate(
		makefile     => 'Makefile.PL',
		existing     => $cpanfile->exists ? $cpanfile->slurp_utf8 : '',
		with_develop => 1,
	);
	$cpanfile->spew_utf8($text);

=head3 HOW IT WORKS

=over 4

=item 1. Check that C<makefile> is a readable, regular file.

=item 2. Read it as UTF-8.  If that fails because of bad UTF-8, warn and
read the raw bytes instead.  Any other read error is passed on.

=item 3. Find C<MIN_PERL_VERSION> and call L</parse_prereqs($content)>.

=item 4. Copy the develop entries from C<existing>, without replacing
entries that came from the F<Makefile.PL>.

=item 5. If C<with_develop> is true, add each configured tool that is
not already in the develop phase.

=item 6. Format and return the text.

=back

=head3 API SPECIFICATION

=head4 Input

	{
		makefile => {
			type     => 'string',
			optional => 1,
			min      => 1,
			default  => 'Makefile.PL',
		},
		existing => {
			type     => 'string',
			optional => 1,
			default  => '',
		},
		with_develop => {
			type     => 'boolean',
			optional => 1,
			default  => 1,
		},
	}

=head4 Output

	{
		type    => 'string',
		matches => qr/\A# Generated from Makefile\.PL using makefilepl2cpanfile\n.*(?<!\n)\n\z/s,
	}

=head4 Domains

Each argument, split into groups of values that behave the same way.
"Refused" means the call dies with C<Cannot read '...'>.

	makefile
	  valid:    a readable regular file, given as a relative path, an
	            absolute path, or an object that stringifies to one
	            (e.g. Path::Tiny).  Any characters the file system allows,
	            including spaces, non-ASCII letters and shell characters.
	  default:  undef or not given -> 'Makefile.PL'
	  refused:  '' and '0' (unless such a file exists), a missing file,
	            a directory, a device, a FIFO, a symlink loop, a file
	            without read permission, any reference (filehandle, glob,
	            array, hash, code)
	  limits:   a file name component up to the file system's NAME_MAX
	            (usually 255 bytes) is accepted; one byte more is refused.
	            File size: 0 bytes gives just the header line; there is
	            no upper limit other than memory.

	existing
	  valid:    any string.  Only the first on 'develop' => sub { ... };
	            block is used; its closing "};" must start a line (after
	            optional spaces or tabs).  'develop' or "develop".
	  default:  undef or not given -> ''
	  ignored:  a string without a develop block, a block that is never
	            closed, a reference (its "HASH(0x...)" text has no block)
	  entries:  0 or more; each needs a valid module name; a version, if
	            given, must be a version number (see parse_prereqs)

	with_develop
	  true:     any true Perl value, including 'yes' and '0.0'
	  false:    0, '0', ''
	  default:  undef or not given -> true

	combinations
	  - with_develop false does not stop the existing develop block from
	    being kept; it only stops tools being added.
	  - An empty Makefile.PL with an existing develop block gives the
	    header plus that develop block.
	  - A configuration file with an empty "develop: {}" adds no tools.

=head3 MESSAGES

Errors (the call dies):

	Cannot read '$makefile'
	    The path does not exist, is not a regular file (for example a
	    directory, a device or a FIFO), cannot be read, or is not a path
	    at all (for example a filehandle).
	    What to do: check the path and its permissions.

	Failed to parse $cfg_file: $error
	    The configuration file exists but contains invalid YAML, cannot be
	    read, or its location cannot be checked (for example "Permission
	    denied").  A missing file, or something that is not a regular
	    file, is simply treated as "no configuration".
	    What to do: fix the YAML or the permissions, or delete the file.

	(any other error while reading the Makefile.PL)
	    A real read error, such as a disk failure, is passed on unchanged.

Warnings (processing continues):

	Warning: '$makefile' contains invalid UTF-8; reading as raw bytes: $error
	    The file is not valid UTF-8.  Its raw bytes are used instead.
	    Note: depending on which optional UTF-8 modules are installed
	    (Unicode::UTF8, PerlIO::utf8_strict), Path::Tiny may instead
	    decode the file leniently and print its own warning.  Either way
	    you get a warning, not an error.
	    What to do: save the Makefile.PL as UTF-8.

	Ignoring invalid version for '$module' in existing cpanfile: '$version'
	    A develop entry in the existing cpanfile has a version that is
	    not a version number.  The entry is kept with no version, so the
	    bad value cannot change the meaning of the new cpanfile.

	No 'develop' key found in $cfg_file; using defaults
	    The configuration file has no develop: section.
	    What to do: add one, or delete the file.

	Skipping invalid module name in $cfg_file: '$module'
	    A name in the develop: section is not a valid module name.  It is
	    ignored.

	Skipping invalid version for '$module' in $cfg_file: '$version'
	    A version in the develop: section is not a version number.  The
	    module is kept with no minimum version.

=cut

sub generate {
	# Accept both flat hash and single-hashref calling styles.
	my $args = Params::Get::get_params(undef, \@_);

	# File tests and the reads below (including the config file) change
	# errno; restore the caller's $! on every exit path.
	local $!;

	# Stringify so a filehandle, glob or other reference is judged by the
	# same "Cannot read" guard as a bad path, rather than being accepted by
	# -f (which also tests open handles) and then misread as a path.
	my $makefile = "@{[ $args->{makefile} // 'Makefile.PL' ]}";
	my $existing = $args->{existing}     // '';
	my $with_dev = $args->{with_develop} // 1;

	croak "Cannot read '$makefile'" unless -f $makefile && -r _;

	my $content;
	{
		local $@;
		eval { $content = path($makefile)->slurp_utf8 };
		if ($@) {
			# Only degrade gracefully for encoding errors; re-throw true I/O failures
			# so callers can distinguish a corrupt file from an unreadable one.
			die $@ unless $@ =~ /decode|ill-formed|utf/i;
			carp "Warning: '$makefile' contains invalid UTF-8; reading as raw bytes: $@";
			$content = path($makefile)->slurp_raw;
		}
	}
	my $min_perl = _parse_min_perl($content);
	my $deps     = parse_prereqs($content);

	# Merge the develop block from a pre-existing cpanfile so that
	# hand-curated entries (all relationship types) survive regeneration.
	# The closing '}; ' is anchored to the start of a line (/m) so that
	# an inline comment containing '}; ' does not terminate the match early,
	# silently dropping any module entries that follow the comment.
	if ($existing =~ /on\s+["']develop["']\s*=>\s*sub\s*\{(.*?)^[ \t]*};/ms) {
		my $dev_block = $1;

		# A commented-out line is not an entry.  '#' cannot occur in a valid
		# module name or version, so stripping to end of line is safe.
		$dev_block =~ s/#[^\n]*//g;

		for my $rel (@REL_ORDER) {
			# \Q$rel\E: quote metacharacters defensively (rel is a constant word,
			# but interpolation without quoting is a static-analysis red flag).
			# [^'"\n]++ possessive: never cross a line boundary when capturing a
			# module name or version, and commit immediately - no backtracking into
			# individual chars needed once the quote is closed.
			# Quotes must match, or "A'B" would be read as a different module.
			while ($dev_block =~ /\b\Q$rel\E\s+(?:'([^'\n]++)'|"([^"\n]++)")(?:\s*,\s*(?:'([^'\n]*+)'|"([^"\n]*+)"))?/g) {
				# Save immediately: the inner validation regex below has no capturing
				# groups, so running it directly against $1 would reset $1/$2 to
				# undef - the classic "inner match clobbers outer capture vars" bug.
				my ($mod, $ver) = ($1 // $2, $3 // $4);
				next unless $mod =~ $MODULE_NAME_RE;
				# SECURITY: the version is written back inside a single-quoted
				# literal; a value such as '\' would escape the closing quote and
				# turn following entries into executable code.
				# length(undef) is undef, so one test covers "absent" and "empty":
				# only a non-empty version can be invalid.
				if (length($ver // q{}) && !_valid_version($ver)) {
					carp "Ignoring invalid version for '$mod' in existing cpanfile: '$ver'";
					$ver = 0;
				}
				$deps->{develop}{$rel}{$mod} //= { version => $ver || 0, comment => undef };
			}
		}
	}

	if ($with_dev) {
		my $config = _load_develop_config();

		# Premise 1: a listed tool must never be added again or overwritten.
		# Premise 2: "listed" means present under any relationship.
		# Conclusion: build that set once, then add every tool outside it.
		# ($dev is a copy of the reference or a fresh {}, so reading it
		# cannot autovivify $deps->{develop} or its relationship hashes.)
		my $dev = $deps->{develop} || {};
		my %listed = map { $_ => 1 } map { keys %{ $dev->{$_} || {} } } @REL_ORDER;
		for my $mod (grep { !$listed{$_} } keys %{$config}) {
			$deps->{develop}{requires}{$mod} = { version => $config->{$mod}, comment => undef };
		}
	}

	return _emit($deps, $min_perl);
}

=head2 parse_prereqs($content)

=head3 PURPOSE

Finds every dependency listed in the text of a F<Makefile.PL> and returns
them grouped by phase and relationship.  This is the parser that
L</generate(%args)> uses; call it directly when you want the data rather
than a F<cpanfile>.  The text is never run.

=head3 ARGUMENTS

=over 4

=item * C<$content> - the text of a F<Makefile.PL>, as a character string
(see L</ENCODING>).  C<undef> or a reference is treated as text with no
dependencies.

=back

The forms that are recognised are listed in L</What it reads>.  These
rules also apply:

=over 4

=item * Only entries whose name is in quotes and is a valid module name
are used.  Several entries may be on one line; a C<#> comment at the end
of a line belongs to the last entry on that line.

=item * Commented-out code is ignored, including a whole dependency list
written on one line after a C<#>.

=item * A version must contain at least one digit and use only C<0-9>,
C<.>, C<_> and a leading C<v>.  Anything else (for example C<'.'> or
C<$VERSION>) means "no minimum version".

=item * When a module appears twice in the same phase and relationship,
the first one wins.  The simple keys are read before C<prereqs> blocks.

=item * C<recommends> and C<suggests> inside a C<prereqs> block belong to
that block's phase; only the ones directly inside C<META_MERGE> go to
C<runtime>.

=back

=head3 RETURNS

A hash reference as described in L</DATA STRUCTURE>.  It is empty when
nothing is found.

=head3 SIDE EFFECTS

None.  It reads no files, prints no warnings, and does not change the
caller's C<$@>, C<$!> or C<$_>.

=head3 USAGE EXAMPLE

	use App::makefilepl2cpanfile;
	use Path::Tiny;

	my $deps = App::makefilepl2cpanfile::parse_prereqs(
		path('Makefile.PL')->slurp_utf8
	);

	# Which test modules are needed, and which minimum versions?
	my $test = $deps->{test}{requires} || {};
	for my $module (sort keys %{$test}) {
		printf "%-30s %s\n", $module, $test->{$module}{version} || 'any';
	}

=head3 API SPECIFICATION

=head4 Input

	{
		content => {
			type     => 'string',
			optional => 1,
			position => 0,
		},
	}

=head4 Output

	{
		type => 'hashref',
	}

=head4 Domains

	content
	  valid:    any string (decoded characters; see ENCODING)
	  empty:    '', undef, any reference, text with no dependency lists
	            -> {} (no warning)

	module name (the quoted key of an entry)
	  valid:    ASCII letter or '_' first, then ASCII letters, digits and
	            '_', in parts joined by '::'.  Shortest: one character
	            ('A', '_').  No maximum length.
	  ignored:  '' ; leading digit ('1A') ; '::' at either end ; ':::' ;
	            '-', space, ';' or the old "'" package separator ;
	            any non-ASCII character ; a bareword (unquoted) key

	version (the value of an entry, and MIN_PERL_VERSION)
	  valid:    the whole value is an optional 'v' followed by ASCII
	            digits, '.' and '_', with at least one digit:
	            '1', 1.60, 'v1.2.3', '1.23_01', '5.010001'
	  zero:     '0', 0, '0.0', '0.000', 'v0', 'v0.0.0' -> "no minimum"
	            (nothing is written)
	  invalid:  -> "no minimum": '.', '_', 'v', '1e3', '1.0-TRIAL',
	            '1 0', non-ASCII digits, $VERSION, version->parse(...),
	            and version ranges such as '>= 1.2, < 2.0' (not supported)
	  limits:   no maximum length

	phase / relationship (inside prereqs blocks)
	  valid:    exactly runtime, configure, build, test, develop /
	            requires, recommends, suggests (lower case)
	  ignored:  anything else, including 'Runtime', 'recommend', 'x_foo'

	comment (text after '#' on an entry's line)
	  kept:     any printable Unicode: accents, 'ss'-type letters, emoji,
	            combining marks, right-to-left scripts
	  removed:  control characters other than TAB (for example CR) and
	            the bidirectional control characters U+061C, U+200E,
	            U+200F, U+202A-U+202E, U+2066-U+2069, which could make the
	            generated file display differently from its real content
	  empty:    a comment that is empty after this -> undef

=head3 MESSAGES

None.  Text that is not recognised is ignored without a warning.

=cut

sub parse_prereqs {
	my $content = $_[0];

	# The POD contract is "no errors or warnings - unrecognised content is
	# silently ignored."  Undef and references are not valid Str inputs; return
	# {} immediately to avoid "uninitialized value" and "reference used as
	# string" warnings from the pattern-match operators below.
	return {} unless defined $content && !ref $content;

	my %deps;
	my $comments = _comment_spans($content);

	# ---- Simple dependency keys (PREREQ_PM, BUILD_REQUIRES, etc.) ----
	# These always map to the 'requires' relationship in their phase.
	for my $mf_key (keys %PHASE_MAP) {
		my $phase = $PHASE_MAP{$mf_key};

		# The regex allows up to four levels of brace nesting so that unusual
		# Makefile.PL constructs (e.g. version objects) don't terminate the
		# block match prematurely.
		while ($content =~ /
			\b $mf_key \s*=>\s* \{
				( (?: [^{}]++
				    | \{ (?: [^{}]++ | \{ (?: [^{}]++ | \{ [^}]*+ \} )* \} )* \}
				  )*
				)
			\}
		/gsx) {
			my $block = $1;
			next if _in_comment($comments, $-[0]);
			_extract_pairs($block, \%deps, $phase, 'requires');
		}
	}

	# ---- Structured 'prereqs' blocks (CPAN Meta Spec style) ----
	# These can appear at the top level of WriteMakefile() or nested inside
	# META_MERGE; both are covered by searching the full content for 'prereqs'.
	# The [start, end) offset of each block is recorded so that the legacy
	# 'recommends'/'suggests' scan below can skip relationship blocks nested inside it.
	my @prereqs_spans;
	while ($content =~ /
		\b prereqs \s*=>\s* \{
			( (?: [^{}]++
			    | \{ (?: [^{}]++
			         | \{ (?: [^{}]++ | \{ (?: [^{}]++ | \{ [^}]*+ \} )* \} )* \}
			      )* \}
			  )*
			)
		\}
	/gsx) {
		my $prereqs_block = $1;
		my @span = ($-[0], $+[0]);
		next if _in_comment($comments, $span[0]);
		push @prereqs_spans, \@span;

		# Each direct child is a phase name mapping to a relationship hash.
		while ($prereqs_block =~ /
			\b (\w+) \s*=>\s* \{
				( (?: [^{}]++ | \{ (?: [^{}]++ | \{ [^}]*+ \} )* \} )* )
			\}
		/gsx) {
			my ($phase_name, $phase_block) = ($1, $2);
			next unless $VALID_PHASE{$phase_name};

			# Each child of the phase block is a relationship name.
			while ($phase_block =~ /
				\b (\w+) \s*=>\s* \{
					( (?: [^{}]++ | \{ [^}]*+ \} )* )
				\}
			/gsx) {
				my ($rel, $rel_block) = ($1, $2);
				next unless $VALID_REL{$rel};

				_extract_pairs($rel_block, \%deps, $phase_name, $rel);
			}
		}
	}

	# ---- Legacy top-level 'recommends' / 'suggests' ----
	# e.g. META_MERGE => { recommends => { 'Mod' => 0 } }.  META spec 1.x
	# defines a top-level 'recommends' as runtime recommendations; a
	# top-level 'suggests' is treated the same way (runtime suggestions).
	# Occurrences inside a 'prereqs' block are phase-scoped and have
	# already been handled above, so skip them.
	while ($content =~ /
		\b (recommends|suggests) ['"]? \s*=>\s* \{
			( (?: [^{}]++ | \{ [^}]*+ \} )* )
		\}
	/gsx) {
		my ($rel, $block, $start) = ($1, $2, $-[0]);
		next if any { $start >= $_->[0] && $start < $_->[1] } @prereqs_spans;
		next if _in_comment($comments, $start);
		_extract_pairs($block, \%deps, 'runtime', $rel);
	}

	return \%deps;
}

# -----------------------------------------------------------------------
# Private helpers
# -----------------------------------------------------------------------

# _extract_pairs
#
# Purpose:  Parse a raw block of text (the content between the outermost
#           braces of a dependency hash) into module/version/comment triples
#           and store them in the deps structure.  Processes line-by-line
#           so that trailing inline comments can be captured before the
#           comment text is discarded.
# Entry:    $_[0] - raw block text (between the outer braces).
#           $_[1] - hashref to populate (the top-level %deps).
#           $_[2] - phase name string (e.g. 'runtime').
#           $_[3] - relationship string (e.g. 'requires').
# Exit:     Returns nothing - mutates $_[1] in place.
# Effects:  Modifies the deps hashref; no I/O.
#
# First-occurrence-wins: if the same module appears multiple times (e.g.
# once in PREREQ_PM and once in a prereqs block), the first parsed entry
# is kept.
sub _extract_pairs {
	my ($block, $deps, $phase, $rel) = @_;

	for my $line (split /\n/, $block) {
		# Capture any trailing inline comment before stripping it.
		# (.*\S) is O(N): greedy .* scans to end, then gives back trailing
		# spaces one by one until \S anchors on the last non-space char.
		# Avoids the super-linear behaviour of (.+?)\s*$ which re-evaluates
		# \s*$ at every expanded position of the lazy quantifier.
		my ($comment) = ($line =~ /#\s*(.*\S)/);
		if (defined $comment) {
			$comment =~ s/$UNSAFE_COMMENT_CHARS_RE//g;
			$comment =~ s/\A\s+|\s+\z//g;
			$comment = undef if $comment eq q{};
		}
		$line =~ s/#.*$//;

		# A line may hold several entries ('A' => 0, 'B' => 0); take them all.
		my @pairs;
		# Opening and closing quotes must match: with ['"]...['"] the key
		# "A'B" was read as 'B" and recorded as a different module, B.
		while ($line =~ /(?:'([^'\n]++)'|"([^"\n]++)")\s*=>\s*$VALUE_TOKEN_RE?/g) {
			push @pairs, [ $1 // $2, $3 // $4 // $5 ];
		}

		for my $i (0 .. $#pairs) {
			my ($mod, $ver) = @{ $pairs[$i] };
			# Defense-in-depth: [^'"]+ already excludes quote characters, but
			# it would accept spaces, ';' and non-ASCII look-alikes.  Only a
			# real module name may reach the generated cpanfile.
			next unless $mod =~ $MODULE_NAME_RE;
			# '.' or '_' alone is not a version; emitting it would produce a
			# cpanfile that CPAN::Meta::Requirements rejects.
			# _valid_version(undef) is false, so no separate defined() test.
			$ver = 0 unless _valid_version($ver);
			# First occurrence wins - do not overwrite already-parsed entries.
			# A trailing comment belongs to the entry it follows: the last.
			# TODO: Data Flow Anomaly - D~: when the last pair on a line is
			# rejected above, the line's comment is captured but never stored,
			# even if an earlier pair on the same line was kept.
			$deps->{$phase}{$rel}{$mod} //= {
				version => $ver,
				comment => $i == $#pairs ? $comment : undef,
			};
		}
	}

	return;
}

# _parse_min_perl
#
# Purpose:  Extract the MIN_PERL_VERSION value from Makefile.PL text.
# Entry:    $_[0] - raw Makefile.PL content string.
# Exit:     The version string (e.g. '5.010'), or undef if not declared.
sub _parse_min_perl {
	my $content = $_[0];
	return undef unless defined $content;	## no critic (ProhibitExplicitReturnUndef)
	return undef unless $content =~ /\bMIN_PERL_VERSION\b\s*=>\s*$VALUE_TOKEN_RE/;	## no critic (ProhibitExplicitReturnUndef)
	my $ver = $1 // $2 // $3;
	return _valid_version($ver) ? $ver : undef;
}

# _comment_spans
#
# Purpose:  Find every '#' comment in the content, so that a commented-out
#           one-line dependency hash is not parsed as live.  One linear pass;
#           the result is queried with _in_comment for each candidate block.
# Entry:    $_[0] - content string.
# Exit:     ArrayRef of [start, end) offsets, ascending and non-overlapping,
#           each running from an unquoted '#' to the end of its line.
sub _comment_spans {
	my $content = $_[0];
	my @spans;
	my $offset = 0;
	for my $line (split /\n/, $content, -1) {
		# Blank out quoted strings (keeping offsets) so that a '#' inside
		# e.g. 'C#' is not mistaken for a comment.
		(my $masked = $line) =~ s/('[^']*+'|"[^"]*+")/'x' x length $1/ge;
		my $hash = index($masked, '#');
		push @spans, [ $offset + $hash, $offset + length $line ] if $hash >= 0;
		$offset += length($line) + 1;
	}
	return \@spans;
}

# _in_comment
#
# Purpose:  Decide whether an offset lies inside one of the comment spans.
# Entry:    $_[0] - ArrayRef from _comment_spans; $_[1] - offset.
# Exit:     Boolean.  Binary search, so O(log n) per query.
sub _in_comment {
	my ($spans, $pos) = @_;
	my ($lo, $hi) = (0, $#{$spans});
	while ($lo <= $hi) {
		my $mid = int(($lo + $hi) / 2);
		my ($start, $end) = @{ $spans->[$mid] };
		if ($pos < $start) { $hi = $mid - 1 }
		elsif ($pos >= $end) { $lo = $mid + 1 }
		else { return 1 }
	}
	return 0;
}

# _valid_version
#
# Purpose:  Decide whether a string is a plausible version number that is
#           safe to write inside a single-quoted cpanfile literal.
# Entry:    $_[0] - candidate version string.
# Exit:     Boolean: an optional leading 'v' followed only by ASCII digits,
#           dots and underscores, with at least one digit.
sub _valid_version {
	my $ver = $_[0];
	return 0 unless defined $ver;
	return $ver =~ /\Av?[0-9._]++\z/ && $ver =~ /[0-9]/ ? 1 : 0;
}

# _load_develop_config
#
# Return the develop-tools hash from the user's YAML config file,
#   or %DEFAULT_DEVELOP when no config file exists.
# Entry:    None - reads from the filesystem at a well-known path.
# Exit:     HashRef { Module::Name => minimum_version_or_0 }.
# Effects:  Reads from disk. Croaks on YAML parse failure. Carps when the
#           config file lacks a 'develop' key.
sub _load_develop_config {
	# Path::Tiny and YAML::Tiny use eval internally, which resets $@; keep the
	# caller's value intact so an enclosing eval/$@ check is not disturbed.
	local $@;

	# Guard: no usable home directory (containers, chroots, CI).  length()
	# of undef is undef, so one test rejects both undef and ''.
	my $home = File::HomeDir->my_home;
	return {%DEFAULT_DEVELOP} unless length($home // q{});

	my $cfg_path = path($home)->child('.config', 'makefilepl2cpanfile.yml');

	# Guard: the path cannot be examined.  A missing file means "use the
	# defaults"; any other stat failure (EACCES, ELOOP, stale NFS...) must not
	# silently change the output.
	my @stat = stat "$cfg_path";
	unless (@stat) {
		croak "Failed to parse $cfg_path: $!" unless $!{ENOENT} || $!{ENOTDIR};
		return {%DEFAULT_DEVELOP};
	}

	# Guard: not a regular file.  A FIFO would block the read forever and a
	# device could stream without end.  The mode bits come from @stat, not
	# from Perl's implicit '_' buffer, which another stat could replace.
	return {%DEFAULT_DEVELOP} unless Fcntl::S_ISREG($stat[2]);

	# Guard: unreadable or invalid YAML.  YAML::Tiny reports failure by dying
	# (current versions) or by returning false with errstr set (older ones);
	# both become the single documented message, without YAML::Tiny's own
	# location.
	my $yaml = eval { YAML::Tiny->read("$cfg_path") };
	unless ($yaml) {
		my $err = $@ || YAML::Tiny->errstr() // q{};
		$err =~ s/ at \S+ line \d+\.?\n?\z//;
		croak "Failed to parse $cfg_path: $err";
	}

	# Guard: no develop hash.  Checking the document's type first means a
	# document that is not a hash is never dereferenced.
	my $doc     = $yaml->[0];
	my $develop = ref $doc eq 'HASH' ? $doc->{develop} : undef;
	unless (ref $develop eq 'HASH') {
		carp "No 'develop' key found in $cfg_path; using defaults";
		return {%DEFAULT_DEVELOP};
	}

	# SECURITY: validate every key (module name) and value (version) before
	# use.  Keys are arbitrary strings: without this guard a key such as
	# "Safe'; system('evil'); requires 'X" would close the quoted literal in
	# _fmt_dep and inject code into the generated cpanfile, which cpanm runs.
	my %clean;
	for my $mod (keys %{$develop}) {
		unless ($mod =~ $MODULE_NAME_RE) {
			carp "Skipping invalid module name in $cfg_path: '$mod'";
			next;
		}
		# Premise 1: a null value means "any version", i.e. 0.
		# Premise 2: _valid_version accepts '0' (it contains a digit).
		# Conclusion: '' is the only extra value that needs allowing.
		my $v = $develop->{$mod} // 0;
		unless ($v eq q{} || _valid_version($v)) {
			carp "Skipping invalid version for '$mod' in $cfg_path: '$v'";
			$v = 0;
		}
		$clean{$mod} = $v;
	}
	return \%clean;
}

# _emit
#
# Purpose:  Pure formatter - converts the structured dependency hash and an
#           optional minimum Perl version into a valid cpanfile string.
# Entry:    $_[0] - HashRef (see DATA STRUCTURE section in POD)
#           $_[1] - optional Str minimum Perl version (e.g. '5.010')
# Exit:     Scalar string; always terminated with exactly one newline.
#           Never returns undef.
#
# Runtime deps are emitted at the top level (no 'on' block) per cpanfile
# convention. All other phases get 'on phase => sub { ... }' blocks.
# Within each phase, relationships are emitted in @REL_ORDER order;
# modules within each relationship are sorted alphabetically.
# Inline comments are re-emitted after the semicolon on the same line.
# A version of 0 or '' means "any version" and is omitted.
sub _emit {
	my ($deps, $min_perl) = @_;

	# Build the output as a list of sections joined by blank lines.
	my @sections = ($HEADER);
	push @sections, "requires 'perl', '$min_perl';" if _has_version($min_perl);

	# Runtime is emitted at the top level; every other phase in an 'on'
	# block, in @PHASE_ORDER.  Both use the same line builder.
	for my $phase ('runtime', @PHASE_ORDER) {
		my $indent = $phase eq 'runtime' ? q{} : "\t";
		my $body = join q{}, map { _fmt_dep(@{$_}, $indent) } @{ _phase_entries($deps->{$phase}) };
		# Premise: an absent phase, or one whose relationships are all
		# empty, yields no entries.  Conclusion: it yields no section.
		next if $body eq q{};
		push @sections, $phase eq 'runtime'
			? $body =~ s/\n\z//r		# the blank-line separator is added by join
			: "on '$phase' => sub {\n$body};";
	}

	return join("\n\n", @sections) . "\n";
}

# _phase_entries
#
# Purpose:  List one phase's entries in output order: relationships in
#           @REL_ORDER, modules alphabetically within each.
# Entry:    $_[0] - the phase's hashref ({ rel => { module => entry } }),
#           or undef when the phase is absent.
# Exit:     ArrayRef of [ rel, module, entry ] triples; empty when none.
sub _phase_entries {
	my $phase = $_[0] || {};
	my @entries;
	for my $rel (@REL_ORDER) {
		my $mods = $phase->{$rel} || {};
		push @entries, [ $rel, $_, $mods->{$_} ] for sort keys %{$mods};
	}
	return \@entries;
}

# _fmt_dep
#
# Purpose:  Format a single dependency line for cpanfile output, including
#           the optional version constraint and inline comment.
# Entry:    $_[0] - relationship keyword (e.g. 'requires', 'recommends').
#           $_[1] - module name string.
#           $_[2] - entry hashref { version => ..., comment => ... }.
#           $_[3] - indentation prefix ('' for runtime, "\t" for phase blocks).
# Exit:     A complete formatted line, including trailing newline.
sub _fmt_dep {
	my ($rel, $mod, $entry, $indent) = @_;

	my $line = "${indent}$rel '$mod'";
	$line .= ", '$entry->{version}'" if _has_version($entry->{version});

	# Premise 1: every producer of entries stores a comment that is undef
	# or non-empty (_extract_pairs turns an empty comment into undef; merged
	# and configured entries have none).  Premise 2: _fmt_dep is only called
	# by _emit on such entries.  Conclusion: defined() is sufficient.
	if (defined $entry->{comment}) {
		$line .= ";   # $entry->{comment}\n";
	} else {
		$line .= ";\n";
	}

	return $line;
}

# _has_version
#
# Decide whether a version value represents a real minimum version
#	constraint that should be written into the cpanfile output.
# Entry:    $_[0] - version value (scalar, possibly undef or numeric '0').
# Exit:     Boolean: true if the version should be emitted; false if it
#           means "any version" (undef, empty string, or numeric zero).
sub _has_version {
	my $ver = $_[0];

	# Premise 1: every version that reaches here is undef, 0, '' or a string
	# accepted by _valid_version (ASCII digits, '.', '_', optional 'v').
	# Premise 2: such a value is zero exactly when none of its digits is
	# 1-9 ('0', '0.000', 'v0.0.0', '0_0').
	# Conclusion: "contains a digit from 1 to 9" is the whole test.
	return defined $ver && $ver =~ /[1-9]/ ? 1 : 0;
}

1;

__END__

=head1 DESIGN NOTES

Some checks are made once, where data enters, and relied on afterwards.
Each rule below is proved by F<t/logic.t>.

=over 4

=item * B<Versions.>  Every version is checked when it is read (from the
F<Makefile.PL>, the existing F<cpanfile> or the configuration file) and
replaced by C<0> if it is not a version number.  A version number is
zero exactly when none of its digits is 1 to 9.  So, when the output is
written, "does it contain a digit from 1 to 9?" is the whole test for
whether to print a minimum version.

=item * B<Comments.>  An empty comment is stored as "no comment" when it
is read, and entries from other sources have no comment.  So, when the
output is written, a comment that exists is never empty and can be
printed without further checks.

=item * B<Developer tools.>  A tool must not be added if the develop
phase already lists it under any relationship.  So the set of listed
modules is built once, and every configured tool outside that set is
added.

=item * B<Order of checks.>  Each function stops at the first check that
fails: an unreadable F<Makefile.PL> is refused before anything is read,
and the configuration file is only parsed once it is known to exist and
to be a regular file.

=back

=head1 LIMITATIONS

=over 4

=item * The F<Makefile.PL> is read with patterns, not run, so dependencies
that are computed by code cannot be found (see L</COMMON PITFALLS>).

=item * Dependency lists nested more than four braces deep inside a
single entry are not fully read.  Normal F<Makefile.PL> files never
come close to this.

=item * Only one C<on 'develop'> section of an existing F<cpanfile> is
used: the first one.

=back

=head1 SEE ALSO

=over 4

=item * L<makefilepl2cpanfile> - the command-line tool

=item * L<Module::CPANfile>, L<cpanfile> - the F<cpanfile> format

=item * L<CPAN::Meta::Spec> - the meaning of phases and relationships

=item * L<ExtUtils::MakeMaker> - the F<Makefile.PL> format

=item * L<Test Dashboard|https://nigelhorne.github.io/App-makefilepl2cpanfile/coverage/>

=back

=head1 SUPPORT

This module is provided as-is without any warranty.

Please report bugs and feature requests at
L<https://github.com/nigelhorne/App-makefilepl2cpanfile/issues>.

=head1 AUTHOR

Nigel Horne E<lt>njh@nigelhorne.comE<gt>

=head1 FORMAL SPECIFICATION

The specifications below use Z notation.  They describe what each
function computes; the English sections above are the normative
description for everyday use.

=head2 Basic types and helpers

	[CHAR, PATH]
	Str       == seq CHAR
	ModName   == { s : Str | s matches [A-Za-z_][A-Za-z0-9_]*(::[A-Za-z0-9_]+)* }
	VersionStr == { s : Str | s matches v?[0-9._]+ ∧ (∃ c ∈ ran s • c ∈ '0'..'9') }
	Phase     ::= runtime | configure | build | test | develop
	Rel       ::= requires | recommends | suggests
	Entry     == [ version : VersionStr ∪ {0}; comment : Str ∪ {⊥} ]
	DepMap    == Phase ⇸ (Rel ⇸ (ModName ⇸ Entry))

	-- Left-biased merge: entries already present win.
	_⊕ₗ_ : DepMap × DepMap -> DepMap
	a ⊕ₗ b == a ∪ { p ↦ (r ↦ (m ↦ e)) ∈ b | m ∉ dom(a(p)(r)) }

	-- Environment read by generate (it is never modified).
	Env ≙ [ fs : PATH ⇸ seq BYTE; home : PATH ∪ {⊥} ]
	cfg(E) == E.home ⁀ "/.config/makefilepl2cpanfile.yml"

=head2 parse_prereqs

	parse_prereqs : (Str ∪ {⊥}) -> DepMap

	parse_prereqs(s) ==
	  if s = ⊥ ∨ is_ref(s) then ∅
	  else simple(s') ⊕ₗ structured(s') ⊕ₗ legacy(s')
	  where s' == s with every '#' comment removed

	simple(s)     == ⋃ { {PHASE_MAP(k) ↦ {requires ↦ pairs(b)}}
	                     | k ∈ {PREREQ_PM, BUILD_REQUIRES, TEST_REQUIRES, CONFIGURE_REQUIRES},
	                       b ∈ blocks(k, s) }
	structured(s) == ⋃ { {p ↦ {r ↦ pairs(b)}}
	                     | P ∈ blocks(prereqs, s), (p ↦ (r ↦ b)) ∈ P, p ∈ Phase, r ∈ Rel }
	legacy(s)     == ⋃ { {runtime ↦ {r ↦ pairs(b)}}
	                     | r ∈ {recommends, suggests}, b ∈ blocks(r, s),
	                       ¬ (∃ P ∈ blocks(prereqs, s) • b ⊆ P) }
	pairs(b)      == { m ↦ ⟨ if v ∈ VersionStr then v else 0, comment(m, b) ⟩
	                     | ('m' => v) ∈ b, m ∈ ModName }

	post  ∀ p ↦ R ∈ result • R ≠ ∅ ∧ (∀ r ↦ M ∈ R • M ≠ ∅)
	      ∧ no I/O ∧ no warnings

=head2 generate

	Args ≙ [ makefile : Str; existing : Str; with_develop : 𝔹 ]

	generate : Args × Env ⇸ Str

	pre   string(a.makefile) ∈ dom E.fs ∧ regular(a.makefile) ∧ readable(a.makefile)
	      ∧ (a.with_develop ⇒ cfg(E) ∉ dom E.fs ∨ ¬ regular(cfg(E)) ∨ yaml_ok(cfg(E)))

	generate(a, E) ==
	  let content == decode_utf8_or_raw(E.fs(a.makefile))
	      deps    == parse_prereqs(content)
	      kept    == { r ↦ { m ↦ ⟨ valid_or_0(v), ⊥ ⟩ }
	                   | (r m v) ∈ develop_entries(a.existing) \ comments, m ∈ ModName }
	      dev     == deps ⊕ₗ {develop ↦ kept}
	      listed  == ⋃ { dom(dev(develop)(r)) | r ∈ Rel }
	      tools   == if E.home = ⊥ ∨ E.home = "" ∨ ¬ regular(cfg(E)) then DEFAULT_DEVELOP
	                 else valid_entries(yaml(cfg(E)).develop)
	      final   == if a.with_develop
	                 then dev ⊕ₗ {develop ↦ {requires ↦ { m ↦ ⟨v, ⊥⟩ | (m ↦ v) ∈ tools, m ∉ listed }}}
	                 else dev
	  in  emit(final, min_perl(content))

	post  result ∈ Str
	      ∧ prefix(result, HEADER ⁀ "\n") ∧ last(result) = '\n' ∧ ¬ suffix(result, "\n\n")
	      ∧ E′ = E                           -- nothing is written
	      ∧ $@′ = $@ ∧ $!′ = $! ∧ $_′ = $_

	-- Failure cases (the function dies):
	¬ regular(a.makefile) ∨ ¬ readable(a.makefile)  ⇒  croak("Cannot read '" ⁀ a.makefile ⁀ "'")
	a.with_develop ∧ regular(cfg(E)) ∧ ¬ yaml_ok(cfg(E))  ⇒  croak("Failed to parse " ⁀ cfg(E) ⁀ ": " ⁀ err)
	a.with_develop ∧ stat(cfg(E)) fails with errno ∉ {ENOENT, ENOTDIR}  ⇒  croak("Failed to parse " ⁀ cfg(E) ⁀ ": " ⁀ errno)

=head1 STATE DIAGRAM

The module keeps no state between calls: every call starts at START and
ends at RETURN or at an error.  The diagram shows the states that one
call to C<generate()> passes through.  C<parse_prereqs()> is the single
step PARSE.

	+-------+
	| START |  generate(%args) is called
	+-------+
	    |
	    | makefile is a readable regular file?
	    |---- no ------------------------------------> [DIE] croak "Cannot read '...'"
	    | yes
	    v
	+------------+  read as UTF-8
	| READ_UTF8  |---- decode error --> +-----------+  carp "invalid UTF-8"
	+------------+                      | READ_RAW  |  (read the raw bytes)
	    |     \                         +-----------+
	    |      \---- other I/O error --------------------------> [DIE] error passed on
	    | ok                                 |
	    v                                    |
	+------------+ <-------------------------+
	|   PARSE    |  parse_prereqs(content); find MIN_PERL_VERSION
	+------------+  (pure: no I/O, no warnings)
	    |
	    | existing has an on 'develop' section?
	    |---- no ----------------------------+
	    | yes                                |
	    v                                    |
	+------------+  copy entries; drop       |
	|   MERGE    |  bad names; carp and      |
	+------------+  drop bad versions        |
	    |                                    |
	    +<-----------------------------------+
	    |
	    | with_develop true?
	    |---- no ----------------------------------------------+
	    | yes                                                  |
	    v                                                      |
	+------------+  no home dir, or config path missing        |
	| CONFIG     |  or not a regular file -------> DEFAULTS    |
	+------------+                                   |         |
	    | config is a regular file                   |         |
	    |---- stat/read/YAML error --> [DIE] croak "Failed to parse ..."
	    v                                            |         |
	+------------+  no develop: key --> carp --> DEFAULTS      |
	| VALIDATE   |  bad name    --> carp, skip entry           |
	+------------+  bad version --> carp, version 0            |
	    |                                            |         |
	    v                                            v         |
	+------------+ <---------------------------------+         |
	|   INJECT   |  add tools not already in develop           |
	+------------+                                             |
	    |                                                      |
	    v                                                      |
	+------------+ <-------------------------------------------+
	|    EMIT    |  format the text (sorted, fixed order)
	+------------+
	    |
	    v
	+--------+
	| RETURN |  the cpanfile text; no file written;
	+--------+  caller's $@, $! and $_ unchanged

The command-line tool adds one final step after RETURN: it writes
F<cpanfile> (default), prints the text (C<--dry-run>), or prints a diff
(C<--diff>).  A write error ends the program with a non-zero exit status
and leaves any existing F<cpanfile> unchanged.

=head1 LICENSE AND COPYRIGHT

Copyright 2025-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.

=cut

