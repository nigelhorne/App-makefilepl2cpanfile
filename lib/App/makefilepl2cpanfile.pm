package App::makefilepl2cpanfile;

use strict;
use warnings;

use File::Slurp qw(read_file);
use YAML::Tiny;
use File::HomeDir;

our $VERSION = '0.02';

sub generate {
    my (%args) = @_;

    my $makefile = $args{makefile} || 'Makefile.PL';
    my $existing = $args{existing} || '';
    my $with_dev = $args{with_develop};

    my %deps;
    my $min_perl;

    my $content = read_file($makefile);

    # ----------------------------
    # MIN_PERL_VERSION
    # ----------------------------
    if ($content =~ /MIN_PERL_VERSION\s*=>\s*['"]?([\d._]+)['"]?/) {
        $min_perl = $1;
    }

    # ----------------------------
    # Map Makefile.PL keys to phases
    # ----------------------------
    my %map = (
        PREREQ_PM          => 'runtime',
        BUILD_REQUIRES     => 'build',
        TEST_REQUIRES      => 'test',
        CONFIGURE_REQUIRES => 'configure',
    );

    # ----------------------------
    # Extract dependency hashes (robust version)
    # ----------------------------
    for my $mf_key (keys %map) {
        my $phase = $map{$mf_key};

        # Match the hash for this key, tolerate nested braces (simple)
        while ($content =~ /
            $mf_key \s*=>\s* \{
                ( (?: [^{}] | \{[^}]*\} )*? )
            \}
        /gsx) {
            my $block = $1;

            # Capture all 'Module' => 'Version' pairs
            while ($block =~ /
                ['"]([^'"]+)['"]      # module
                \s*=>\s*
                ['"]?([\d._]+)?['"]?  # version
            /gx) {
                $deps{$phase}{$1} = $2 // 0;
            }
        }
    }

    # ----------------------------
    # Preserve existing develop block
    # ----------------------------
    if ($existing =~ /on\s+'develop'\s*=>\s*sub\s*\{(.*?)\};/s) {
        while ($1 =~ /requires\s+['"]([^'"]+)['"](?:\s*,\s*['"]([^'"]+)['"])?/g) {
            $deps{develop}{$1} //= $2 // 0;
        }
    }

    # ----------------------------
    # Post-processing hook: develop deps
    # ----------------------------
    if ($with_dev) {
        $deps{develop} ||= {};

        my %default = (
            'Perl::Critic'        => 0,
            'Devel::Cover'        => 0,
            'Test::Pod'           => 0,
            'Test::Pod::Coverage' => 0,
        );

        my $cfg_file = File::HomeDir->my_home . '/.config/makefilepl2cpanfile.yml';
        if (-r $cfg_file) {
            my $y = YAML::Tiny->read($cfg_file)->[0];
            %default = %{ $y->{develop} } if $y->{develop};
        }

        for my $mod (keys %default) {
            $deps{develop}{$mod} //= $default{$mod};
        }
    }

    # ----------------------------
    # Emit cpanfile text
    # ----------------------------
    return _emit(\%deps, $min_perl);
}

sub _emit {
    my ($deps, $min_perl) = @_;

    my $out = "# Generated from Makefile.PL\n\n";
    $out .= "perl '$min_perl';\n\n" if $min_perl;

    # Runtime dependencies at top level
    if (my $rt = $deps->{runtime}) {
        for my $m (sort keys %$rt) {
            $out .= "requires '$m'";
            $out .= ", '$rt->{$m}'" if $rt->{$m};
            $out .= ";\n";
        }
        $out .= "\n";
    }

    # Other phases
    for my $phase (qw(configure build test develop)) {
        my $h = $deps->{$phase} or next;
        next unless %$h;

        $out .= "on '$phase' => sub {\n";
        for my $m (sort keys %$h) {
            $out .= "    requires '$m'";
            $out .= ", '$h->{$m}'" if $h->{$m};
            $out .= ";\n";
        }
        $out .= "};\n\n";
    }

    return $out;
}

1;
