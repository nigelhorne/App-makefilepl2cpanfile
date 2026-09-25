## Name

App::makefilepl2cpanfile - Convert Makefile.PL to a cpanfile automatically

## Version

This document describes App::makefilepl2cpanfile version 0.04.

## Synopsis

Create or refresh the `cpanfile` of the project in the current directory:

```perl
    use App::makefilepl2cpanfile;
    use Path::Tiny;

    my $text = App::makefilepl2cpanfile::generate();
    path('cpanfile')->spew_utf8($text);
```

Keep the hand-written `develop` section of an existing `cpanfile`:

```perl
    my $old  = path('cpanfile')->slurp_utf8;
    my $text = App::makefilepl2cpanfile::generate(existing => $old);
    path('cpanfile')->spew_utf8($text);
```

Make a `cpanfile` for another project, with no developer tools added.
The result is the same on every computer, which is useful in CI:

```perl
    my $text = App::makefilepl2cpanfile::generate({
            makefile     => '/path/to/other/project/Makefile.PL',
            with_develop => 0,
    });
```

List every dependency without making a `cpanfile`:

```perl
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
```

Check in a test that the committed `cpanfile` is up to date:

```perl
    use Test::More;
    is(
            App::makefilepl2cpanfile::generate(existing => path('cpanfile')->slurp_utf8),
            path('cpanfile')->slurp_utf8,
            'cpanfile matches Makefile.PL',
    );
```

From the command line (see [makefilepl2cpanfile](https://metacpan.org/pod/makefilepl2cpanfile)):

```
    makefilepl2cpanfile              # write ./cpanfile
    makefilepl2cpanfile --dry-run    # print it instead
    makefilepl2cpanfile --diff       # show what would change
```

## Description

A Perl distribution lists the modules it needs in its `Makefile.PL`.
Many tools (for example `cpanm --installdeps .` and CI systems) prefer
a `cpanfile` instead.  This module reads a `Makefile.PL` and writes the
same list in `cpanfile` form, so you only keep the list in one place.

The `Makefile.PL` is **never run**.  It is read as plain text and
searched for the parts that list dependencies.  This makes the tool safe
to use on code you do not trust, but it also means that it cannot see
dependencies that are computed while the program runs (see
["COMMON PITFALLS"](#common-pitfalls)).

### What It Reads

- `PREREQ_PM`, `BUILD_REQUIRES`, `TEST_REQUIRES` and
`CONFIGURE_REQUIRES`.  These become `requires` lines in the `runtime`,
`build`, `test` and `configure` phases.
- `prereqs => { PHASE => { RELATIONSHIP => { ... } } }`
blocks (the CPAN::Meta::Spec version 2 layout), wherever they appear -
also inside `META_MERGE`.
- `recommends => { ... }` and `suggests => { ... }`
directly inside `META_MERGE` (the older version 1 layout).  These become
`recommends` and `suggests` lines in the `runtime` phase.
- `MIN_PERL_VERSION`, which becomes `requires 'perl', 'VERSION';`.
- A `#` comment after an entry.  It is copied to the `cpanfile`.

### What It Writes

```perl
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
```

Runtime dependencies come first, without an `on` block.  The other
phases follow in this order: `configure`, `build`, `test`, `develop`.
Inside each phase, `requires` lines come first, then `recommends`, then
`suggests`, and the modules are in alphabetical order.  The same input
always gives exactly the same output.

## Configuration

When `with_develop` is true (the default), some developer tools are
added to the `develop` phase.  By default these are [Devel::Cover](https://metacpan.org/pod/Devel%3A%3ACover),
[Perl::Critic](https://metacpan.org/pod/Perl%3A%3ACritic), [Test::Pod](https://metacpan.org/pod/Test%3A%3APod) and [Test::Pod::Coverage](https://metacpan.org/pod/Test%3A%3APod%3A%3ACoverage).

To choose your own list, create the file
`~/.config/makefilepl2cpanfile.yml`:

```
    develop:
      Perl::Critic: 0
      Devel::Cover: 0
      My::Extra::Tool: '1.00'
```

The number after each name is the minimum version; `0` means "any
version".  Your list **replaces** the default list; it is not added to it.
Names that are not valid module names, and versions that are not version
numbers, are ignored with a warning, so a mistake in this file can never
put unexpected code into your `cpanfile`.

## Data Structure

`parse_prereqs()` returns a hash reference with three levels:

```perl
    {
            PHASE => {
                    RELATIONSHIP => {
                            'Module::Name' => { version => '1.0', comment => 'why it is needed' },
                    },
            },
    }
```

- PHASE is one of `runtime`, `configure`, `build`, `test` or
`develop`.
- RELATIONSHIP is one of `requires`, `recommends` or `suggests`.
- `version` is the minimum version exactly as it was written (for
example `'1.60'` stays `'1.60'`).  It is `0` when there is no minimum.
- `comment` is the text of the `#` comment after the entry, or
`undef` when there is none.

A phase or relationship with no modules is not present at all.

## Encoding

- **The Makefile.PL file** is read as UTF-8.  Comments may contain
any Unicode text, including accented letters and emoji; they are copied
to the output unchanged.  If the file is not valid UTF-8 you get a
warning and processing continues (see ["generate(%args)"](#generate-args)).
- **The returned cpanfile text** is a Perl character string.  Write
it with a UTF-8 output layer, for example `path(...)->spew_utf8` or
`binmode $fh, ':encoding(UTF-8)'`.  Otherwise Perl warns
"Wide character in print" when a comment contains non-ASCII text.
- **The existing argument** and **the content argument of
parse\_prereqs()** must be character strings: decode them first (for
example with `slurp_utf8`).  Raw bytes work for plain ASCII, but a
non-ASCII comment would come back as separate bytes.
- **Module names** must be plain ASCII (A-Z, a-z, 0-9, `_` and
`::`), as CPAN requires.  A name with any other character is ignored.
This also stops look-alike names, such as `Test::More` written with a
Cyrillic letter.
- **Version numbers** may use only the ASCII digits 0-9, `.`,
`_` and a leading `v`, and must contain at least one digit.  Anything
else is treated as "no minimum version".
- **The YAML configuration file** is read as UTF-8; the same rules
for names and versions apply.
- **File names** are passed to the operating system unchanged.
Names with spaces, non-ASCII letters or shell characters such as `;`
and `|` are safe: no shell is ever used.

## Common Pitfalls

- **Code in Makefile.PL is not run.**  Dependencies that are built
by code are not seen, for example `PREREQ_PM => \%deps` or a list
returned by a function.  Entries inside a condition, such as
`$^O eq 'MSWin32' ? ('Win32' => 0) : ()`, are seen but become
unconditional.  Write such dependencies as plain entries, or add them to
the `cpanfile` another way.
- **Only the develop section of an existing cpanfile is kept.**
Hand edits anywhere else (for example a `feature` block or an extra
`on 'test'` line) are lost when you regenerate.  Put hand-written
entries in `on 'develop' => sub { ... }`.
- **Conditions inside the kept develop section are removed.**  An
`if (...) { requires 'X' }` inside the develop block is carried over as
a plain `requires 'X'`.  Comments in the develop block are not kept.
- **Which entry wins.**  When the same module is listed twice in the
same phase and relationship, the first one wins.  The simple keys
(`PREREQ_PM` and friends) are read before `prereqs` blocks, and entries
from `Makefile.PL` win over entries in the existing develop section.
The same module under two different relationships (for example
`requires` and `recommends`) is kept twice.
- **The configuration file replaces the default tools.**  If you
list only `My::Tool`, then `Perl::Critic` and the others are no longer
added.  List them too if you want them.
- **undef means "use the default".**  `makefile => undef` reads
`Makefile.PL`; `existing => undef` is the same as `''`; and
`with_develop => undef` means **true**.  Use `with_develop => 0`
to turn developer tools off.
- **parse\_prereqs(undef) is silent.**  It returns an empty hash
reference with no warning, so a failed file read can look like "no
dependencies".  Check that the read worked before you call it.
- **The output depends on who runs it.**  With `with_develop` on,
the tool list comes from the home directory of the current user.  Use
`with_develop => 0` when every computer must produce the same file.
- **generate() does not write any file.**  It returns the text.
Save it yourself (see ["SYNOPSIS"](#synopsis)) or use the command-line tool.
- **Relative paths** in `makefile` are relative to the current
working directory, not to your script.
- **Warnings are not errors.**  Problems such as invalid UTF-8 or a
bad configuration entry are reported with `warn` (through [Carp](https://metacpan.org/pod/Carp)) and
processing continues.  Catch them with `$SIG{__WARN__}` if you need to
act on them.

## Methods

### Generate(%Args)

#### Purpose

Reads a `Makefile.PL` and returns the text of a matching `cpanfile`.
The `Makefile.PL` is read as text and is never run.

#### Arguments

Give the arguments as a list of name/value pairs, or as one hash
reference.  All of them are optional.

- `makefile` - the path of the `Makefile.PL` to read.  Default:
`'Makefile.PL'` in the current directory.  Anything that turns into a
path when used as a string is accepted, such as a [Path::Tiny](https://metacpan.org/pod/Path%3A%3ATiny) object.
A filehandle or another kind of reference is refused with
`Cannot read`.
- `existing` - the text of your current `cpanfile`.  Default:
`''` (none).  Only its `on 'develop' => sub { ... }` section is
used.  Every `requires`, `recommends` and `suggests` line in that
section is copied to the new text, so your hand-written developer
dependencies are kept.  Lines that are commented out are not copied.
An entry whose name is not a valid module name is dropped.  An entry
whose version is not a version number is kept without a version, and
you get a warning.
- `with_develop` - true or false.  Default: true.  When true, the
developer tools from the configuration file (see ["CONFIGURATION"](#configuration)), or
the default tools, are added to the `develop` phase as `requires`.  A
tool that is already in the develop phase, from the `Makefile.PL` or
from `existing`, is left exactly as it is.

#### Returns

A string: the complete `cpanfile`.  It always starts with the line
`# Generated from Makefile.PL using makefilepl2cpanfile` and always ends
with exactly one newline.  The layout is described in
["What it writes"](#what-it-writes).  A `Makefile.PL` with no dependencies gives just
the first line.

#### Side Effects

- Reads the `makefile` file.
- When `with_develop` is true, reads
`~/.config/makefilepl2cpanfile.yml` if it exists.
- Never writes, creates or deletes any file.
- May print warnings (see MESSAGES below).
- Does not change the caller's `$@`, `$!` or `$_`.

#### Usage Example

```perl
    use App::makefilepl2cpanfile;
    use Path::Tiny;

    my $cpanfile = path('cpanfile');
    my $text = App::makefilepl2cpanfile::generate(
            makefile     => 'Makefile.PL',
            existing     => $cpanfile->exists ? $cpanfile->slurp_utf8 : '',
            with_develop => 1,
    );
    $cpanfile->spew_utf8($text);
```

#### How It Works

- 1. Check that `makefile` is a readable, regular file.
- 2. Read it as UTF-8.  If that fails because of bad UTF-8, warn and
read the raw bytes instead.  Any other read error is passed on.
- 3. Find `MIN_PERL_VERSION` and call ["parse\_prereqs($content)"](#parse_prereqs-content).
- 4. Copy the develop entries from `existing`, without replacing
entries that came from the `Makefile.PL`.
- 5. If `with_develop` is true, add each configured tool that is
not already in the develop phase.
- 6. Format and return the text.

#### Api Specification

##### Input

```perl
    {
            makefile => {
                    type     => 'string',
                    optional => 1,
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
```

##### Output

```perl
    {
            type    => 'string',
            matches => qr/\A# Generated from Makefile\.PL using makefilepl2cpanfile\n.*(?<!\n)\n\z/s,
    }
```

#### Messages

Errors (the call dies):

```
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
```

Warnings (processing continues):

```
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
```

### Parse\_Prereqs($Content)

#### Purpose

Finds every dependency listed in the text of a `Makefile.PL` and returns
them grouped by phase and relationship.  This is the parser that
["generate(%args)"](#generate-args) uses; call it directly when you want the data rather
than a `cpanfile`.  The text is never run.

#### Arguments

- `$content` - the text of a `Makefile.PL`, as a character string
(see ["ENCODING"](#encoding)).  `undef` or a reference is treated as text with no
dependencies.

The forms that are recognised are listed in ["What it reads"](#what-it-reads).  These
rules also apply:

- Only entries whose name is in quotes and is a valid module name
are used.  Several entries may be on one line; a `#` comment at the end
of a line belongs to the last entry on that line.
- Commented-out code is ignored, including a whole dependency list
written on one line after a `#`.
- A version must contain at least one digit and use only `0-9`,
`.`, `_` and a leading `v`.  Anything else (for example `'.'` or
`$VERSION`) means "no minimum version".
- When a module appears twice in the same phase and relationship,
the first one wins.  The simple keys are read before `prereqs` blocks.
- `recommends` and `suggests` inside a `prereqs` block belong to
that block's phase; only the ones directly inside `META_MERGE` go to
`runtime`.

#### Returns

A hash reference as described in ["DATA STRUCTURE"](#data-structure).  It is empty when
nothing is found.

#### Side Effects

None.  It reads no files, prints no warnings, and does not change the
caller's `$@`, `$!` or `$_`.

#### Usage Example

```perl
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
```

#### Api Specification

##### Input

```perl
    {
            content => {
                    type     => 'string',
                    optional => 1,
                    position => 0,
            },
    }
```

##### Output

```perl
    {
            type => 'hashref',
    }
```

#### Messages

None.  Text that is not recognised is ignored without a warning.

## Limitations

- The `Makefile.PL` is read with patterns, not run, so dependencies
that are computed by code cannot be found (see ["COMMON PITFALLS"](#common-pitfalls)).
- Dependency lists nested more than four braces deep inside a
single entry are not fully read.  Normal `Makefile.PL` files never
come close to this.
- Only one `on 'develop'` section of an existing `cpanfile` is
used: the first one.

## See Also

- [makefilepl2cpanfile](https://metacpan.org/pod/makefilepl2cpanfile) - the command-line tool
- [Module::CPANfile](https://metacpan.org/pod/Module%3A%3ACPANfile), [cpanfile](https://metacpan.org/pod/cpanfile) - the `cpanfile` format
- [CPAN::Meta::Spec](https://metacpan.org/pod/CPAN%3A%3AMeta%3A%3ASpec) - the meaning of phases and relationships
- [ExtUtils::MakeMaker](https://metacpan.org/pod/ExtUtils%3A%3AMakeMaker) - the `Makefile.PL` format
- [Test Dashboard](https://nigelhorne.github.io/App-makefilepl2cpanfile/coverage/)

## Support

This module is provided as-is without any warranty.

Please report bugs and feature requests at
[https://github.com/nigelhorne/App-makefilepl2cpanfile/issues](https://github.com/nigelhorne/App-makefilepl2cpanfile/issues).

## Author

Nigel Horne <njh@nigelhorne.com>

## Formal Specification

The specifications below use Z notation.  They describe what each
function computes; the English sections above are the normative
description for everyday use.

### Basic Types and Helpers

```
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
```

### Parse\_Prereqs

```perl
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
```

### Generate

```perl
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
```

## State Diagram

The module keeps no state between calls: every call starts at START and
ends at RETURN or at an error.  The diagram shows the states that one
call to `generate()` passes through.  `parse_prereqs()` is the single
step PARSE.

```perl
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
```

The command-line tool adds one final step after RETURN: it writes
`cpanfile` (default), prints the text (`--dry-run`), or prints a diff
(`--diff`).  A write error ends the program with a non-zero exit status
and leaves any existing `cpanfile` unchanged.

## License and Copyright

Copyright 2025-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.
