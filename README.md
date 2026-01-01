# NAME

App::makefilepl2cpanfile - Convert Makefile.PL to a cpanfile automatically

# SYNOPSIS

    use App::makefilepl2cpanfile;

    # Generate a cpanfile string
    my $cpanfile_text = App::makefilepl2cpanfile::generate(
        makefile      => 'Makefile.PL',
        existing      => '',           # optional, existing cpanfile content
        with_develop  => 1,            # include developer dependencies
    );

    # Write to disk
    open my $fh, '>', 'cpanfile' or die $!;
    print $fh $cpanfile_text;
    close $fh;

# DESCRIPTION

This module parses a \`Makefile.PL\` and produces a \`cpanfile\` with:

- Runtime dependencies (\`PREREQ\_PM\`)
- Build, test, and configure requirements (\`BUILD\_REQUIRES\`, \`TEST\_REQUIRES\`, \`CONFIGURE\_REQUIRES\`)
- Optional author/development dependencies in a \`develop\` block

The parsing is done \*\*safely\*\*, without evaluating the Makefile.PL.

# CONFIGURATION

You may create a YAML file in:

    ~/.config/makefilepl2cpanfile.yml

with a structure like:

    develop:
      Perl::Critic: 0
      Devel::Cover: 0
      Test::Pod: 0
      Test::Pod::Coverage: 0

This will override the default development tools.

# METHODS

## generate(%args)

Generates a cpanfile string.

Arguments:

- makefile

    Path to \`Makefile.PL\`. Defaults to \`'Makefile.PL'\`.

- existing

    Optional string containing an existing cpanfile. Existing \`develop\` blocks are merged.

- with\_develop

    Boolean. Include default or configured author tools. Defaults to true if not overridden.

Returns the cpanfile as a string.

# AUTHOR

Nigel Horne <njh@nigelhorne.com>

# LICENSE AND COPYRIGHT

This software is licensed under the same terms as Perl itself.
