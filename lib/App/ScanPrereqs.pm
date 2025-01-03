package App::ScanPrereqs;

use 5.010001;
use strict;
use warnings;
use Log::ger;

# AUTHORITY
# DATE
# DIST
# VERSION

our %SPEC;

$SPEC{scan_prereqs} = {
    v => 1.1,
    summary => 'Scan files/directories for prerequisites',
    description => <<'MARKDOWN',

This is an alternative CLI to <pm:scan_prereqs>, with the following features:

* merged output

scan_prereqs by default reports prereqs per source file, which may or may not be
what you want. This CLI outputs a single list of prerequisites found from all
input.

Aside from that, you can use `--json` to get a JSON output.

* option to pick backend

Aside from <pm:Perl::PrereqScanner> you can also use
<pm:Perl::PrereqScanner::Lite> and <pm:Perl::PrereqScanner::NotQuiteLite>.

* filter only core or non-core prerequisites.

MARKDOWN
    args => {
        files => {
            'x.name.is_plural' => 1,
            'x.name.singular' => 'file',
            schema => ['array*', of=>'pathname*'],
            default => ['.'],
            pos => 0,
            slurpy => 1,
        },
        scanner => {
            schema => ['str*', in=>['regular','lite','nqlite']],
            default => 'regular',
            summary => 'Which scanner to use',
            description => <<'MARKDOWN',

`regular` means <pm:Perl::PrereqScanner> which is PPI-based and is the slowest
but has the most complete support for Perl syntax.

`lite` means <pm:Perl::PrereqScanner::Lite> uses an XS-based lexer and is the
fastest but might miss some Perl syntax (i.e. miss some prereqs) or crash if
given some weird code.

`nqlite` means <pm:Perl::PrereqScanner::NotQuiteLite> which is faster than
`regular` but not as fast as `lite`.

Read respective scanner's documentation for more details about the pro's and
con's for each scanner.

MARKDOWN
        },
        perlver => {
            summary => 'Perl version to use when determining core/non-core',
            description => <<'MARKDOWN',

The default is the current perl version.

MARKDOWN
            schema => 'str*',
        },
        show_core => {
            schema => ['bool*'],
            default => 1,
            summary => 'Whether or not to show core prerequisites',
        },
        show_noncore => {
            schema => ['bool*'],
            default => 1,
            summary => 'Whether or not to show non-core prerequisites',
        },
    },
    examples => [
        {
            summary => 'By default scan current directory',
            args => {},
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
};
sub scan_prereqs {
    require Filename::Type::Backup;
    require File::Find;

    my %args = @_;

    my $perlver = version->parse($args{perlver} // $^V);

    my $scanner = do {
        if ($args{scanner} eq 'lite') {
            require Perl::PrereqScanner::Lite;
            my $scanner = Perl::PrereqScanner::Lite->new;
            $scanner->add_extra_scanner('Moose');
            $scanner->add_extra_scanner('Version');
            $scanner;
        } elsif ($args{scanner} eq 'nqlite') {
            require Perl::PrereqScanner::NotQuiteLite;
            my $scanner = Perl::PrereqScanner::NotQuiteLite->new(
                parsers  => [qw/:installed -UniversalVersion/],
                suggests => 1,
            );
            $scanner;
        } else {
            require Perl::PrereqScanner;
            Perl::PrereqScanner->new;
        }
    };

    my %mods;
    my %excluded_mods;

    require File::Find;
    File::Find::find(
        sub {
            no warnings 'once';

            return unless -f;
            my $path = "$File::Find::dir/$_";
            if (Filename::Type::Backup::check_backup_filename(filename=>$_)) {
                log_debug("Skipping backup file %s ...", $path);
                return;
            }
            if (/\A(\.git)\z/) {
                log_debug("Skipping %s ...", $path);
                return;
            }
            log_debug("Scanning file %s ...", $path);
            my $scanres = $scanner->scan_file($_);

            # if we use PP::NotQuiteLite, it returns PPN::Context which supports
            # a 'requires' method to return a CM:Requirements like the other
            # scanners
            my $prereqs = $scanres->can("requires") ?
                $scanres->requires->as_string_hash : $scanres->as_string_hash;

            if ($scanres->can("suggests") && (my $sugs = $scanres->suggests)) {
                # currently it's not clear what makes PP:NotQuiteLite determine
                # something as a suggests requirement, so we include suggests as
                # a normal requires requirement.
                $sugs = $sugs->as_string_hash;
                for (keys %$sugs) {
                    $prereqs->{$_} ||= $sugs->{$_};
                }
            }

            for my $mod (keys %$prereqs) {
                next if $excluded_mods{$mod};
                my $v = $prereqs->{$mod};
                if ($mod eq 'perl') {
                } elsif (!$args{show_core} || $args{show_noncore}) {
                    require Module::CoreList;
                    my $ans = Module::CoreList->is_core(
                        $mod, $v, $perlver);
                    if ($ans && !$args{show_core}) {
                        log_debug("Skipped prereq %s %s (core)", $mod, $v);
                        $excluded_mods{$mod} = 1;
                        next;
                    } elsif (!$ans && !$args{show_noncore}) {
                        log_debug("Skipped prereq %s %s (non-core)", $mod, $v);
                        $excluded_mods{$mod} = 1;
                        next;
                    }
                }
                if (defined $mods{$mod}) {
                    $mods{$mod} = $v if
                        version->parse($v) > version->parse($mods{$mod});
                } else {
                    log_info("Added prereq %s (from %s)", $mod, $path);
                    $mods{$mod} = $v;
                }
            }

        },
        @{ $args{files} },
    );

    my @rows;
    my %resmeta = (
        'table.fields' => [qw/module version/],
    );
    for my $mod (sort {lc($a) cmp lc($b)} keys %mods) {
        push @rows, {module=>$mod, version=>$mods{$mod}};
    }

    [200, "OK", \@rows, \%resmeta];
}

1;
#ABSTRACT:

=head1 SYNOPSIS

 # Use via lint-prereqs CLI script

=cut
