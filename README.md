## Name

App::makefilepl2cpanfile - Convert Makefile.PL to a cpanfile automatically

## Version

## Synopsis

```perl
    use App::makefilepl2cpanfile;

    my $cpanfile_text = App::makefilepl2cpanfile::generate(
            makefile     => 'Makefile.PL',
            existing     => '',   # optional: existing cpanfile text to merge
            with_develop => 1,    # include author/developer dependencies
    );

    path('cpanfile')->spew_utf8($cpanfile_text);
```

## Description

Parses a `Makefile.PL` file **without evaluating it** and produces a
`cpanfile` string containing:

- Runtime dependencies (`PREREQ_PM`)
- Build, test, and configure requirements (`BUILD_REQUIRES`,
`TEST_REQUIRES`, `CONFIGURE_REQUIRES`)
- Structured `prereqs => { phase => { rel => { ... } } }`
blocks (CPAN Meta Spec format), including `recommends` and `suggests`
relationships
- Legacy top-level `recommends => { ... }` and
`suggests => { ... }` blocks (META spec 1.x style, typically inside
`META_MERGE`), emitted as runtime `recommends` / `suggests`
- Inline comments attached to dependency entries
- Optional author/development dependencies in a `develop` block

## Configuration

An optional YAML file at `~/.config/makefilepl2cpanfile.yml` overrides
the default develop-phase tools:

```
    develop:
      Perl::Critic: 0
      Devel::Cover: 0
      My::Extra::Tool: '1.00'
```

## Data Structure

`parse_prereqs()` and the internal pipeline use a three-level hashref:

```perl
    {
      phase_name => {
        relationship => {
          'Module::Name' => { version => '1.0', comment => 'why it is needed' },
        },
      },
    }
```

`phase_name` ∈ { runtime, configure, build, test, develop }.
`relationship` ∈ { requires, recommends, suggests }.
`version` is `0` when no minimum is declared.
`comment` is `undef` when no inline comment was present.

## Methods

### Generate(%Args)

#### Purpose

Parses a `Makefile.PL` **without evaluating it** and returns the text of an
equivalent `cpanfile`.

#### Arguments

Named arguments, passed either as a flat list or as a single hashref:

- `makefile` (Str, optional, default `'Makefile.PL'`) - path to the
`Makefile.PL` to read.  Relative paths are resolved against the current
working directory.  The value is used as a string: an object that
stringifies to a path (such as a [Path::Tiny](https://metacpan.org/pod/Path%3A%3ATiny) object) is accepted, while a
filehandle or other reference is rejected with `Cannot read`.
- `existing` (Str, optional, default `''`) - the text of an existing
`cpanfile`.  Only its `on 'develop' => sub { ... }` block is used:
every `requires`, `recommends` and `suggests` entry in it is carried over
into the output.  Commented-out lines are not entries.  Entries whose module
name is not a valid Perl package name are dropped; an entry whose version
is not a version number is kept with no minimum version, with a warning.
- `with_develop` (Bool, optional, default true) - when true, the
develop tools from the user configuration (see ["CONFIGURATION"](#configuration)), or the
built-in defaults `Devel::Cover`, `Perl::Critic`, `Test::Pod` and
`Test::Pod::Coverage`, are added to the `develop` phase as `requires`.
A tool already listed in the develop phase under any relationship, whether
from the `Makefile.PL` or from `existing`, is never added again or
overwritten.

#### Returns

A Str containing the complete cpanfile, beginning with the line
`# Generated from Makefile.PL using makefilepl2cpanfile` and terminated by
exactly one newline.  When `MIN_PERL_VERSION` is declared as a version
number a `requires 'perl', 'VERSION';` line follows the header.  Runtime
dependencies are emitted at the top level; all other phases are emitted in
`on 'phase' => sub { ... };` blocks in the order configure, build,
test, develop.  Within each phase entries are grouped requires, recommends,
suggests and sorted alphabetically.  Inline comments from the source are
reproduced after the entry.

#### Side Effects

Reads `makefile` and, when `with_develop` is true, the configuration file
`~/.config/makefilepl2cpanfile.yml`.  Never writes to disk.  May emit
warnings via `carp` (see ["MESSAGES"](#messages)).  The caller's `$@`, `$!` and
`$_` are left unchanged.

#### Usage Example

```perl
    use App::makefilepl2cpanfile;
    use Path::Tiny;

    # Minimal usage - generate from the project's own Makefile.PL
    my $out = App::makefilepl2cpanfile::generate();
    path('cpanfile')->spew_utf8($out);

    # Preserve hand-curated develop entries from an existing cpanfile
    $out = App::makefilepl2cpanfile::generate({
            makefile     => 'dist/Makefile.PL',
            existing     => path('cpanfile')->slurp_utf8,
            with_develop => 0,
    });
```

#### Pseudocode

```
    1. Validate and normalise arguments; croak if makefile is unreadable.
    2. Slurp makefile content as UTF-8; on a decoding error warn and
       re-read as raw bytes; re-throw any other I/O error.
    3. Extract MIN_PERL_VERSION; call parse_prereqs() on the content.
    4. If an existing cpanfile string was supplied, merge its 'develop'
       block (all relationships) without overwriting freshly-parsed entries.
    5. If with_develop: load user config (or built-in defaults) and inject
       missing 'requires' develop tools - never overwrite explicit entries.
    6. Format and return the cpanfile string.
```

#### Api Specification

##### Input

```perl
    {
            makefile     => { type => 'string',  optional => 1, default => 'Makefile.PL' },
            existing     => { type => 'string',  optional => 1, default => '' },
            with_develop => { type => 'boolean', optional => 1, default => 1 },
    }
```

##### Output

```perl
    {
            type    => 'string',
            matches => qr/\A# Generated from Makefile\.PL using makefilepl2cpanfile\n.*(?<!\n)\n\z/s,
    }
```

#### Formal Specification

```perl
    Args ≙ [ makefile : Path; existing : Str; with_develop : 𝔹 ]

    generate : Args ⇸ Str

    pre  readable(a.makefile) ∧ is_file(a.makefile)
         ∧ (a.with_develop ⇒ ¬ exists(cfg) ∨ parses(cfg))

    generate(a) ≙
      let content ≙ slurp(a.makefile)
          deps    ≙ parse_prereqs(content)
          dev     ≙ deps.develop ⊕ (extract_develop(a.existing) ⩤ deps.develop)
          listed  ≙ ⋃ { dom(dev(r)) | r ∈ dom(dev) }
          inject  ≙ if a.with_develop
                    then listed ⩤ { m ↦ ⟨v, ⊥⟩ | (m ↦ v) ∈ load_config() }
                    else ∅
          final   ≙ deps ⊕ { develop ↦ dev ⊕ { requires ↦ dev.requires ∪ inject } }
      in emit(final, min_perl(content))

    post result ∈ Str ∧ last(result) = '\n' ∧ ¬ suffix(result, "\n\n")
         ∧ disk′ = disk ∧ $@′ = $@ ∧ $!′ = $! ∧ $_′ = $_
```

#### Messages

```perl
    "Cannot read '$makefile'"  (croak)
        The supplied path does not exist, is a directory, or is not readable.
        Resolution: verify the path and filesystem permissions.

    "Warning: '$makefile' contains invalid UTF-8; reading as raw bytes: $error"  (carp)
        The file could not be decoded as UTF-8; it is re-read as raw bytes
        and processing continues.
        Resolution: re-save Makefile.PL as UTF-8.

        Which decoder Path::Tiny uses depends on optional modules
        (Unicode::UTF8, PerlIO::utf8_strict).  Some decode invalid bytes
        leniently with their own warning instead of failing; in that case
        this message is not issued but processing still continues, so
        invalid UTF-8 always yields a warning and never an exception.

    Any other error raised while reading the file (die)
        Genuine I/O failures are re-thrown unchanged rather than masked.

    "Failed to parse $cfg_file: $error"  (croak)
        The user config file exists but contains invalid YAML, cannot be
        read, or its path cannot be examined (e.g. permission denied).  A
        path that does not exist, or that is not a regular file (a
        directory, device or FIFO), is treated as no config file.
        Resolution: validate the YAML syntax and permissions; or delete the
        file to use defaults.

    "No 'develop' key found in $cfg_file; using defaults"  (carp)
        The config file exists but lacks a 'develop' section.
        Resolution: add a develop: block, or delete the file to use defaults.

    "Ignoring invalid version for '$module' in existing cpanfile: '$version'"  (carp)
        A develop entry in the existing cpanfile has a version that is not
        a version number.  It is written back with no minimum version, so
        that it cannot alter the syntax of the generated cpanfile.

    "Skipping invalid module name in $cfg_file: '$module'"  (carp)
        A key under 'develop' is not a valid Perl package name; it is ignored
        so it cannot inject code into the generated cpanfile.

    "Skipping invalid version for '$module' in $cfg_file: '$version'"  (carp)
        A version under 'develop' is not a version number; the module is
        kept with no minimum version.
```

### Parse\_Prereqs($Content)

#### Purpose

Extracts all dependency declarations from the text of a `Makefile.PL` and
returns them structured by cpanfile phase and relationship.  Exposed as a
public function so callers (e.g. `bin/makefilepl2cpanfile --check`) can
reuse the parsing logic without duplicating it.  The text is never
evaluated.

#### Arguments

- `$content` (Str) - the raw text of a `Makefile.PL`.  An undefined
value or a reference is treated as containing no dependencies.

The following forms are recognised:

- `PREREQ_PM`, `BUILD_REQUIRES`, `TEST_REQUIRES` and
`CONFIGURE_REQUIRES` hashes, mapped to the `requires` relationship of the
`runtime`, `build`, `test` and `configure` phases respectively.
- Structured `prereqs => { phase => { rel => { ... } } }`
blocks (CPAN Meta Spec 2), wherever they appear, including under
`META_MERGE`.  Only the phases and relationships listed in
["DATA STRUCTURE"](#data-structure) are used; any others are ignored.
- Legacy (META spec 1.x style) top-level `recommends => { ... }`
and `suggests => { ... }` hashes, typically under `META_MERGE`,
mapped to the `runtime` phase.  Such hashes inside a `prereqs` block
belong to that block's phase only.

Only entries whose key is a quoted, valid Perl package name are used.
Commented-out code is skipped, including a whole dependency hash written on
one line after a `#`.  A version is an optional `v` followed by ASCII
digits, dots and underscores containing at least one digit; anything else
(for example `'.'`) is treated as no minimum version.  When a module appears more than once in
the same phase and relationship, the first occurrence wins, and the simple
keys are read before `prereqs` blocks.

#### Returns

A HashRef as described in ["DATA STRUCTURE"](#data-structure).  Phases and relationships
with no entries are absent.  `version` is `0` when no minimum is
declared; `comment` holds the text of an inline `#` comment on the entry,
or `undef` when there is none.

#### Side Effects

None.  No I/O, no warnings, and the caller's `$@`, `$!` and `$_` are
left unchanged.

#### Usage Example

```perl
    use App::makefilepl2cpanfile;
    use Path::Tiny;

    my $deps = App::makefilepl2cpanfile::parse_prereqs(
            path('Makefile.PL')->slurp_utf8
    );

    for my $phase (sort keys %{$deps}) {
            for my $rel (sort keys %{ $deps->{$phase} }) {
                    for my $mod (sort keys %{ $deps->{$phase}{$rel} }) {
                            my $e = $deps->{$phase}{$rel}{$mod};
                            printf "%s %s %s => %s\n", $phase, $rel, $mod, $e->{version};
                    }
            }
    }
```

#### Api Specification

##### Input

```perl
    {
            content => { type => 'string', optional => 1 },
    }
```

##### Output

```perl
    {
            type => 'hashref',
    }
```

#### Formal Specification

```
    Phase   ::= runtime | configure | build | test | develop
    Rel     ::= requires | recommends | suggests
    Entry   ≙ [ version : VersionStr; comment : Str ∪ {⊥} ]
    DepMap  ≙ Phase ⇸ (Rel ⇸ (ModName ⇸ Entry))

    parse_prereqs : Str ∪ {⊥} → DepMap

    parse_prereqs(s) ≙
      if s = ⊥ ∨ is_ref(s) then ∅
      else simple(s) ⊕ₗ structured(s) ⊕ₗ legacy(s)
    where
      simple(s)     ≙ ⋃ { {PHASE_MAP(k) ↦ {requires ↦ pairs(b)}} | k ∈ dom(PHASE_MAP), b ∈ blocks(k, s) }
      structured(s) ≙ ⋃ { {p ↦ {r ↦ pairs(b)}} | P ∈ prereqs(s), (p ↦ (r ↦ b)) ∈ P, p ∈ Phase, r ∈ Rel }
      legacy(s)     ≙ ⋃ { {runtime ↦ {r ↦ pairs(b)}} | r ∈ {recommends, suggests},
                          b ∈ blocks(r, s), ¬ (∃ P ∈ prereqs(s) • b ⊆ P) }
      -- ⊕ₗ is left-biased override: the first occurrence of a module wins

    post ∀ p ↦ R ∈ result • R ≠ ∅ ∧ ∀ r ↦ M ∈ R • M ≠ ∅
         ∧ ∀ m ∈ dom(M) • m ∈ ModName
```

#### Messages

None.  Unrecognised content is silently ignored.

## Limitations

- Because parsing is regex-based and the `Makefile.PL` is never
`eval`'d, dynamically generated dependency lists (e.g. those produced by
`if`/`unless` branches or subroutine calls) cannot be detected.
- Encapsulation enforcement (`Sub::Private` in `enforce` mode) is not
applied; the `_` prefix convention is used instead.  A future release may
add `Sub::Private` once its `enforce`-mode API is verified.

## Support

This module is provided as-is without any warranty.

Bugs and feature requests:
[https://github.com/nigelhorne/App-makefilepl2cpanfile/issues](https://github.com/nigelhorne/App-makefilepl2cpanfile/issues)

## See Also

- [Test Dashboard](https://nigelhorne.github.io/App-makefilepl2cpanfile/coverage/)

## Author

Nigel Horne <njh@nigelhorne.com>

## Licence and Copyright

Copyright 2025-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.
