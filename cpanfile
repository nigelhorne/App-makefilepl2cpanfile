# Generated from Makefile.PL using makefilepl2cpanfile

requires 'perl', '5.010';

requires 'File::HomeDir';
requires 'IPC::System::Simple';
requires 'List::Util', '1.33';
requires 'Params::Get', '0.17';
requires 'Path::Tiny';
requires 'Readonly';
requires 'Text::Diff';
requires 'YAML::Tiny';
requires 'autodie';

on 'configure' => sub {
	requires 'ExtUtils::MakeMaker', '6.64';   # Minimum version for TEST_REQUIRES
};

on 'test' => sub {
	requires 'Capture::Tiny';
	requires 'File::Temp';
	requires 'Module::CPANfile';
	requires 'Test::Carp';
	requires 'Test::Compile';
	requires 'Test::DescribeMe';
	requires 'Test::Memory::Cycle';
	requires 'Test::Mockingbird';
	requires 'Test::Most';
	requires 'Test::NoWarnings';
	requires 'Test::RequiresInternet';
	requires 'Test::Returns', '0.04';
	requires 'Test::Warn';
	requires 'Test::Which';
	requires 'Test::Without::Module';
};

on 'develop' => sub {
	requires 'Devel::Cover';
	requires 'Perl::Critic';
	requires 'Test::Pod';
	requires 'Test::Pod::Coverage';
};
