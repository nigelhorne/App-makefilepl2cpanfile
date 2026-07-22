package App::makefilepl2cpanfile;

use strict;
use warnings;
use autodie qw(:all);
use Carp        qw(croak carp);
use Readonly;
use Scalar::Util qw(looks_like_number);
use Path::Tiny;
use YAML::Tiny;
use File::HomeDir;

=head1 NAME

App::makefilepl2cpanfile - Convert Makefile.PL to a cpanfile automatically

=head1 VERSION

=cut

our $VERSION = '0.02';

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

# Maps each Makefile.PL dependency key to its cpanfile phase name.
Readonly my %PHASE_MAP => (
	BUILD_REQUIRES     => 'build',
	CONFIGURE_REQUIRES => 'configure',
	PREREQ_PM          => 'runtime',
	TEST_REQUIRES      => 'test',
);

# Canonical emit order for non-runtime phases (runtime is special-cased at
# the top level per cpanfile convention).
Readonly my @PHASE_ORDER => qw(configure build test develop);

=head1 SYNOPSIS

	use App::makefilepl2cpanfile;

	my $cpanfile_text = App::makefilepl2cpanfile::generate(
		makefile     => 'Makefile.PL',
		existing     => '',   # optional: existing cpanfile text to merge
		with_develop => 1,    # include author/developer dependencies
	);

	path('cpanfile')->spew_utf8($cpanfile_text);

=head1 DESCRIPTION

Parses a C<Makefile.PL> file B<without evaluating it> and produces a
C<cpanfile> string containing:

=over 4

=item * Runtime dependencies (C<PREREQ_PM>)

=item * Build, test, and configure requirements (C<BUILD_REQUIRES>,
C<TEST_REQUIRES>, C<CONFIGURE_REQUIRES>)

=item * Optional author/development dependencies in a C<develop> block

=back

=head1 CONFIGURATION

An optional YAML file at C<~/.config/makefilepl2cpanfile.yml> overrides
the default develop-phase tools:

	develop:
	  Perl::Critic: 0
	  Devel::Cover: 0
	  My::Extra::Tool: '1.00'

=head1 METHODS

=head2 generate(%args)

Parses a C<Makefile.PL> and returns a complete C<cpanfile> string.

=head3 PSEUDOCODE

	1. Validate and normalise arguments; croak if makefile is unreadable.
	2. Slurp makefile content; extract MIN_PERL_VERSION.
	3. Call parse_prereqs() to extract phase->module->version from content.
	4. If an existing cpanfile string was supplied, merge its 'develop'
	   block into deps without overwriting freshly-parsed entries.
	5. If with_develop: load user config (or built-in defaults) and inject
	   missing develop tools — never overwrite already-set entries.
	6. Delegate to _emit() and return the formatted string.

=head3 API SPECIFICATION

	Arguments (named hash or single hashref):
	  makefile     Str   Path to Makefile.PL.  Default: 'Makefile.PL'
	  existing     Str   Existing cpanfile text to merge.  Default: ''
	  with_develop Bool  Inject default dev tools.  Default: 1 (true)

	Returns: Str — complete cpanfile text, terminated with a single newline.

=head3 EXAMPLE

	# Minimal usage — generate from the project's own Makefile.PL
	my $out = App::makefilepl2cpanfile::generate();
	path('cpanfile')->spew_utf8($out);

	# Preserve hand-curated develop entries from an existing cpanfile
	my $out = App::makefilepl2cpanfile::generate(
		makefile => 'dist/Makefile.PL',
		existing => path('cpanfile')->slurp_utf8,
	);

=head3 MESSAGES

	"Cannot read '$makefile'"
	    The supplied path does not exist or is not readable.
	    Resolution: verify the path and filesystem permissions.

	"Failed to parse $cfg_file: ..."
	    The user config file exists but contains invalid YAML.
	    Resolution: validate the YAML syntax; or delete the file to use defaults.

	"No 'develop' key found in $cfg_file; using defaults"
	    The config file exists but lacks a 'develop' section.
	    Resolution: add a develop: block, or delete the file to use defaults.

=head3 FORMAL SPECIFICATION

	-- generate maps named arguments to a cpanfile string
	generate : Args → Str
	where
	  Args ≙ [makefile : Path; existing : Str; with_develop : 𝔹]

	generate(a) ≙
	  let content ≙ slurp(a.makefile)
	      deps    ≙ parse_prereqs(content)
	      merged  ≙ deps ⊕ {develop ↦
	                   deps.develop ∪ extract_develop(a.existing)}
	      final   ≙ if a.with_develop
	                then merged ⊕ {develop ↦
	                       load_config() ▷ merged.develop}
	                else merged
	  in _emit(final, min_perl(content))
	-- (▷) right-biases toward the right operand: existing entries win.

=cut

sub generate {
	# Accept both flat hash and single-hashref calling styles.
	my %args = (ref $_[0] eq 'HASH') ? %{ $_[0] } : @_;

	my $makefile = $args{makefile}     // 'Makefile.PL';
	my $existing = $args{existing}     // '';
	my $with_dev = $args{with_develop} // 1;

	croak "Cannot read '$makefile'" unless -f $makefile && -r _;

	my $content  = path($makefile)->slurp_utf8;
	my $min_perl = _parse_min_perl($content);
	my $deps     = parse_prereqs($content);

	# Merge the develop block from a pre-existing cpanfile string so that
	# hand-curated entries survive regeneration.
	if ($existing =~ /on\s+["']develop["']\s*=>\s*sub\s*\{(.*?)\};/s) {
		my $dev_block = $1;
		while ($dev_block =~ /requires\s+['"]([^'"]+)['"](?:\s*,\s*['"]([^'"]+)['"])?/g) {
			$deps->{develop}{$1} //= $2 // 0;
		}
	}

	if ($with_dev) {
		$deps->{develop} //= {};
		my $config = _load_develop_config();

		# Only inject tools not already present — explicit entries always win.
		for my $mod (keys %{$config}) {
			$deps->{develop}{$mod} //= $config->{$mod};
		}
	}

	return _emit($deps, $min_perl);
}

=head2 parse_prereqs($content)

Extracts all dependency declarations from a C<Makefile.PL> string and
returns them structured by cpanfile phase.  This is exposed as a public
function so callers (e.g. C<bin/makefilepl2cpanfile --check>) can reuse
the parsing logic without duplicating the regex.

=head3 API SPECIFICATION

	Arguments:
	  $content   Str   Raw text of a Makefile.PL

	Returns: HashRef
	  {
	    runtime   => { 'Module::Name' => version_str, ... },
	    build     => { ... },
	    test      => { ... },
	    configure => { ... },
	  }
	  Absent phases are not present in the hashref.
	  version_str is 0 when no minimum version is declared.

=head3 EXAMPLE

	my $deps = App::makefilepl2cpanfile::parse_prereqs(
	    path('Makefile.PL')->slurp_utf8
	);
	for my $mod (sort keys %{ $deps->{runtime} }) {
	    printf "%s => %s\n", $mod, $deps->{runtime}{$mod};
	}

=head3 MESSAGES

	No errors or warnings — unrecognised content is silently ignored.

=head3 FORMAL SPECIFICATION

	parse_prereqs : Str → DepMap
	where
	  DepMap ≙ Phase ↦ (ModName ↦ VersionStr)
	  Phase  ∈ {runtime, build, test, configure}

	parse_prereqs(s) ≙
	  ⋃ { extract_block(k, s) | k ∈ dom(PHASE_MAP) }
	where
	  extract_block(k, s) ≙
	    PHASE_MAP(k) ↦ { m ↦ v | (m, v) ∈ pairs_in(hash_value_of(k, s)) }

=cut

sub parse_prereqs {
	my ($content) = @_;

	my %deps;

	for my $mf_key (keys %PHASE_MAP) {
		my $phase = $PHASE_MAP{$mf_key};

		# Match the value hash for this key; allow one level of nesting so
		# version strings with dots aren't mistaken for sub-hashes.
		while ($content =~ /
			\b $mf_key \s*=>\s* \{
				( (?: [^{}] | \{ [^}]* \} )*? )
			\}
		/gsx) {
			my $block = $1;
			$block =~ s/#[^\n]*//g;		# strip end-of-line comments

			while ($block =~ /
				['"] ([^'"]+) ['"]
				\s*=>\s*
				['"]? ([\d._]+)? ['"]?
			/gx) {
				$deps{$phase}{$1} = $2 // 0;
			}
		}
	}

	return \%deps;
}

# -----------------------------------------------------------------------
# Private helpers
# -----------------------------------------------------------------------

# _parse_min_perl
#
# Purpose:  Extract the MIN_PERL_VERSION value from Makefile.PL text.
# Entry:    $_[0] — raw Makefile.PL content string.
# Exit:     The version string (e.g. '5.010'), or undef if not declared.
# Effects:  None.
sub _parse_min_perl {
	my ($content) = @_;
	return ($content =~ /MIN_PERL_VERSION\s*=>\s*['"]?([\d._]+)['"]?/)
		? $1
		: undef;
}

# _load_develop_config
#
# Purpose:  Return the develop-tools hash from the user's YAML config file,
#           or %DEFAULT_DEVELOP when no config file exists.
# Entry:    None — reads from the filesystem at a well-known path.
# Exit:     HashRef { Module::Name => minimum_version_or_0 }.
# Effects:  Reads from disk. Croaks on YAML parse failure. Carps when the
#           config file lacks a 'develop' key.
sub _load_develop_config {
	my $cfg_path = path(File::HomeDir->my_home)
		->child('.config', 'makefilepl2cpanfile.yml');

	if ($cfg_path->is_file) {
		my $yaml = YAML::Tiny->read("$cfg_path")
			or croak "Failed to parse $cfg_path: " . YAML::Tiny->errstr();

		if (ref $yaml->[0]{develop} eq 'HASH') {
			return $yaml->[0]{develop};
		}
		carp "No 'develop' key found in $cfg_path; using defaults";
	}

	# Return a copy so callers cannot mutate the constant.
	return {%DEFAULT_DEVELOP};
}

# _emit
#
# Purpose:  Pure formatter — converts the structured dependency hash and an
#           optional minimum Perl version into a valid cpanfile string.
# Entry:    $_[0] — HashRef { phase => { Module => version_str } }
#           $_[1] — optional Str minimum Perl version (e.g. '5.010')
# Exit:     Scalar string; always terminated with exactly one newline.
#           Never returns undef.
# Effects:  None — no I/O, no mutation of arguments.
#
# Notes:
#   Runtime deps are emitted at the top level (no 'on' block) per cpanfile
#   convention. All other phases get explicit 'on phase => sub { ... }' blocks.
#   Modules within each phase are sorted alphabetically for reproducible output.
#   A version of 0 or '' means "any version" and is not emitted.
sub _emit {
	my ($deps, $min_perl) = @_;

	my $out = "# Generated from Makefile.PL using makefilepl2cpanfile\n\n";
	$out .= "requires 'perl', '$min_perl';\n\n" if $min_perl;

	# Runtime dependencies sit at the top level, outside any 'on' block.
	if (my $rt = $deps->{runtime}) {
		for my $m (sort keys %{$rt}) {
			$out .= "requires '$m'";
			$out .= ", '$rt->{$m}'" if _has_version($rt->{$m});
			$out .= ";\n";
		}
		$out .= "\n";
	}

	# Remaining phases each get their own named block, in canonical order.
	my @blocks;
	for my $phase (@PHASE_ORDER) {
		my $h = $deps->{$phase} or next;
		next unless %{$h};

		my $block = "on '$phase' => sub {\n";
		for my $m (sort keys %{$h}) {
			$block .= "\trequires '$m'";
			$block .= ", '$h->{$m}'" if _has_version($h->{$m});
			$block .= ";\n";
		}
		$block .= "};";
		push @blocks, $block;
	}

	$out .= join("\n\n", @blocks) . "\n" if @blocks;
	return $out;
}

# _has_version
#
# Purpose:  Decide whether a version value represents a real minimum version
#           constraint that should be written into the cpanfile output.
# Entry:    $_[0] — version value (scalar, possibly undef or numeric '0').
# Exit:     Boolean: true if the version should be emitted; false if it
#           means "any version" (undef, empty string, or numeric zero).
# Effects:  None.
sub _has_version {
	my ($ver) = @_;
	return 0 unless defined $ver && $ver ne '';

	# Use looks_like_number to avoid spurious non-numeric warnings when
	# comparing against 0 — version strings are always numeric, but be safe.
	return looks_like_number($ver) ? ($ver != 0) : 1;
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * Inline comments attached to dependency entries are not preserved.
For example, C<'Mojolicious' =E<gt> 0, # used in bin/> is emitted without
the comment.

=item * The C<recommends> and C<suggests> relationship types from the CPAN
Meta Spec are not extracted.  Neither the structured C<prereqs =E<gt> {
runtime =E<gt> { recommends =E<gt> { ... } } }> form nor C<META_MERGE>
resources-level recommends are currently handled.

=item * Nested dependency blocks deeper than one level of braces are not
parsed.

=item * Because parsing is regex-based and the C<Makefile.PL> is never
C<eval>'d, dynamically generated dependency lists (e.g. those produced by
C<if>/C<unless> branches or subroutine calls) cannot be detected.

=item * Encapsulation enforcement (C<Sub::Private> in C<enforce> mode) is not
applied; the C<_> prefix convention is used instead.  A future release may
add C<Sub::Private> once its C<enforce>-mode API is verified.

=back

=head1 SUPPORT

Bugs and feature requests:
L<https://github.com/nigelhorne/App-makefilepl2cpanfile/issues>

=head1 AUTHOR

Nigel Horne E<lt>njh@nigelhorne.comE<gt>

=head1 LICENCE AND COPYRIGHT

Copyright 2025-2026 Nigel Horne.

Personal single user, single computer use: GPL2.
All other users must apply in writing for a licence.

=cut
