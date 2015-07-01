# --
# Copyright (C) 2001-2015 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Daemon::DaemonModules::SchedulerCronTaskManager;

use strict;
use warnings;
use utf8;

use Kernel::System::VariableCheck qw(:all);

use base qw(Kernel::System::Daemon::BaseDaemon);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
    'Kernel::System::DB',
    'Kernel::System::Daemon::SchedulerDB',
    'Kernel::System::Log',
);

=head1 NAME

Kernel::System::Daemon::DaemonModules::SchedulerCronTaskManager - daemon to manage scheduler cron tasks

=head1 SYNOPSIS

Scheduler cron task daemon

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create scheduler cron task manager object.

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless $Self, $Type;

    # get objects in constructor to save performance
    $Self->{ConfigObject}      = $Kernel::OM->Get('Kernel::Config');
    $Self->{CacheObject}       = $Kernel::OM->Get('Kernel::System::Cache');
    $Self->{DBObject}          = $Kernel::OM->Get('Kernel::System::DB');
    $Self->{SchedulerDBObject} = $Kernel::OM->Get('Kernel::System::Daemon::SchedulerDB');

    # disable in memory cache to be clusterable
    $Self->{CacheObject}->Configure(
        CacheInMemory  => 0,
        CacheInBackend => 1,
    );

    # get the NodeID from the SysConfig settings, this is used on High Availability systems.
    $Self->{NodeID} = $Self->{ConfigObject}->Get('NodeID') || 1;

    # check NodeID, if does not match is impossible to continue
    if ( $Self->{NodeID} !~ m{ \A \d+ \z }xms && $Self->{NodeID} > 0 && $Self->{NodeID} < 1000 ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "NodeID '$Self->{NodeID}' is invalid!",
        );
        return;
    }

    # Do not change the following values!
    $Self->{SleepPost} = 20;         # sleep 20 seconds after each loop
    $Self->{Discard}   = 60 * 60;    # discard every hour

    $Self->{DiscardCount} = $Self->{Discard} / $Self->{SleepPost};

    return $Self;
}

sub PreRun {
    my ( $Self, %Param ) = @_;

    # check if database is on-line
    return 1 if $Self->{DBObject}->Ping();

    sleep 10;

    return;
}

sub Run {
    my ( $Self, %Param ) = @_;

    return if !$Self->{SchedulerDBObject}->CronTaskToExecute(
        NodeID => $Self->{NodeID},
        PID    => $$,
    );

    return 1;
}

sub PostRun {
    my ( $Self, %Param ) = @_;

    sleep $Self->{SleepPost};

    $Self->{DiscardCount}--;

    # unlock long locked tasks
    $Self->{SchedulerDBObject}->RecurrentTaskUnlockExpired(
        Type => 'Cron',
    );

    # remove obsolete tasks before destroy
    if ( $Self->{DiscardCount} == 0 ) {
        $Self->{SchedulerDBObject}->CronTaskCleanup();
    }

    return if $Self->{DiscardCount} <= 0;
    return 1;
}

sub Summary {
    my ( $Self, %Param ) = @_;

    return $Self->{SchedulerDBObject}->CronTaskSummary();
}

sub DESTROY {
    my $Self = shift;

    return 1;
}

1;
