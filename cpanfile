# Generated from Makefile.PL

perl '5.008';

requires 'ExtUtils::MakeMaker', '6.64';
requires 'File::HomeDir';
requires 'File::Slurp';
requires 'YAML::Tiny';

on 'configure' => sub {
    requires 'ExtUtils::MakeMaker', '6.64';
};

on 'test' => sub {
    requires 'File::Temp';
    requires 'Test::Carp';
    requires 'Test::Compile';
    requires 'Test::DescribeMe';
    requires 'Test::Most';
    requires 'Test::NoWarnings';
    requires 'Test::RequiresInternet';
    requires 'Test::Returns';
    requires 'Test::Warn';
    requires 'Test::Which';
    requires 'autodie';
    requires 'strict';
    requires 'warnings';
};

on 'develop' => sub {
    requires 'Devel::Cover';
    requires 'Perl::Critic';
    requires 'Test::Pod';
    requires 'Test::Pod::Coverage';
};

