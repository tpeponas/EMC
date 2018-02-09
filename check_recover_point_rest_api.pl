#!/usr/bin/perl

#use strict;
#use warnings;
use Switch;
use Getopt::Long;
use JSON;
use LWP::UserAgent;
use IO::Socket::SSL;
use HTTP::Request::Common;
use Data::Dumper;
use POSIX qw(strftime);
#use DateTime;

my $RP_Version="4_4";


# Variable Global

my $cluster;
my $username;
my $password;
my $check_command;
my $group_name;
my $debug;
my $global_status=0;

my %STATUS_EXIT=( 'OK' => 0 ,'WARNING' => 1 , 'CRITICAL' => 2 , 'UNKNOW' => 3 );
my @STATUS_STR=( 'OK','WARNING','CRITICAL','UNKNOW' );

my $ua = LWP::UserAgent->new( ssl_opts => {
    SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
    verify_hostname => 0,
			      });

sub get_snapshot_status {
    # Prend en entré un group_di et un cluster_id
    # Affiche l'heure du dernier snap "Crach Consistent"
    # On vérifier qu'il est dien dans le Dernier RPO localtime - RPO < Snaptime
    # rpo en second

    my ($group_id,$cluster_id,$rpo,$gp_name)=@_;
    my $journal_state='UNKNOW';
    
    # On controle si la copie est en distributing

    my $req = HTTP::Request->new(GET => "https://$cluster/fapi/rest/$RP_Version/groups/state");
    $req->authorization_basic($username,$password);
    my $content= $ua->request($req)->content;
    my $json = JSON->new->utf8->decode($content);

    foreach(@{$json->{'innerSet'}}) {
	if ($group_id == $_->{'groupUID'}{'id'}) {
	    if ($debug) {
		print Dumper($json);
	    }
	    
	    foreach(@{$_->{'groupCopiesState'}}) {
		if ($cluster_id == $_->{'copyUID'}{'globalCopyUID'}{'clusterUID'}{'id'}) {
		    $journal_state=$_->{'journalState'};
		}
	    }	    
	}
    }

    if ($journal_state =~ /DISTRIBUTING/ ) {
    
	$req = HTTP::Request->new(GET => "https://$cluster/fapi/rest/$RP_Version/groups/$group_id/clusters/$cluster_id/copies/0/snapshots");
	$req->authorization_basic($username,$password);
	$content= $ua->request($req)->content;
	$json = JSON->new->utf8->decode($content);
	
	if ($debug) {
	    print Dumper($json);
	}

	my $epoch=int($json->{'latest'}{'timeInMicroSeconds'}/1000000);
	my $now_epoch=time;

	my $datestring = localtime($epoch);
	printf( "Last Snapshot time for $gp_name : $datestring RPO : $rpo second:");
	
	if ($now_epoch-$epoch < $rpo ) {
	    printf("OK \n");
	    if ($group_name !~ /ALL/) {exit $STATU_EXIT{'OK'}; }
	} else {
	    printf("WARNING \n");
	    if ($group_name !~ /ALL/) {exit $STATUS_EXIT{'WARNING'};}
	}
	
    } else {
	printf(" $gp_name is in $journal_state state : WARNING\n");
	if  ($group_name !~ /ALL/) {exit $STATUS_EXIT{'WARNING'};}
    }
    
}


sub get_snapshots_status {
    my $found_gp=0;
        
    # On recupere la liste des groups ID

    my $req = HTTP::Request->new(GET => "https://$cluster/fapi/rest/$RP_Version/groups/settings");
    $req->authorization_basic($username,$password);
    my $content= $ua->request($req)->content;
    my $json = JSON->new->utf8->decode($content);

    foreach(@{$json->{'innerSet'}}) {
	my $gp_name=$_->{'name'};
	if ($group_name =~ /ALL/ || $_->{'name'} =~ /$group_name/) {

	    $found_gp=1;
	    
	    my $group_id=$_->{'groupUID'}{'id'};
	    my $rpo=int($_->{'activeLinksSettings'}[0]{'linkPolicy'}{'protectionPolicy'}{'rpoPolicy'}{'maximumAllowedLag'}{'value'}/1000000);

	    my @cgs=@{$_->{'groupCopiesSettings'}};
	    foreach(@cgs) {
		if ($_->{'roleInfo'}{'role'} =~ /REPLICA/) {
		    my $cluster_id=$_->{'copyUID'}{'globalCopyUID'}{'clusterUID'}{'id'};
		    if ($debug)  {
			print $_->{'name'}.":".$group_id.": Cluster:".$cluster_id."\n";
		    }

		    # On recupere les images snapshots du group $group_id sur le cluster $cluster_id
		    get_snapshot_status($group_id,$cluster_id,$rpo,$gp_name);
		}
	    }
	}
    }
    if (! $found_gp ) {
	printf ("UNKNOW: $group_name not found \n");
	exit  $STATUS_EXIT{'UNKNOW'};
	
    }
    
}


sub get_system_status {
    my %RPA_STATUS = ( 'OK' => 0, 'DOWN' => 1 , 'REMOVED_FOR_MAINTENANCE' => 1,'UNKNOWN' => 3);
    
    # On recupere le cluster ID

    my $req = HTTP::Request->new(GET => "https://$cluster/fapi/rest/$RP_Version/system/local_cluster");
    $req->authorization_basic($username,$password);
    my $content= $ua->request($req)->content;
    my $json = JSON->new->utf8->decode($content);
    my $cluster_id=$json->{'id'};

    $req = HTTP::Request->new(GET => "https://$cluster/fapi/rest/$RP_Version/clusters/$cluster_id/rpas/state");
    $req->authorization_basic($username,$password);
    $content= $ua->request($req)->content;
    $json = JSON->new->utf8->decode($content);

    my @rpas=@{$json->{'rpasState'}};
    foreach (@rpas) {
	my $rpa_id=$_->{'rpaUID'}{'rpaNumber'};
	my $state=$_->{'status'};
	if ($debug) { print "RPA $rpa_id $state\n"; }
	
	$global_status +=  $RPA_STATUS{$state};

	if ($global_status>=3) { $global_status=3; }
    }



    # fabrication output_perf

    my $output_perf = "| ";

    $req = HTTP::Request->new(GET => "https://$cluster/fapi/rest/$RP_Version/clusters/$cluster_id/rpas/statistics");
    $req->authorization_basic($username,$password);
    $content= $ua->request($req)->content;
    $json = JSON->new->utf8->decode($content);
 
    @rpas=@{$json->{'innerSet'}};
    foreach (@rpas) {
	my $rpa_id=$_->{'rpaUID'}{'rpaNumber'};

	my $cpu_pct=$_->{'cpuUsage'}*100.0;
	$output_perf=$output_perf."RPA${rpa_id}_cpu=$cpu_pct".'%;;;0;100 ';

	my $app_in=$_->{'traffic'}{'applicationThroughputStatistics'}{'inThroughput'};
	$output_perf=$output_perf."RPA${rpa_id}_appIn=${app_in}B;;;; ";

	my $app_inc_w=$_->{'traffic'}{'applicationIncomingWrites'};
	$output_perf=$output_perf."RPA${rpa_id}_appInWrite=$app_inc_w;;;; ";
	
	if ($_->{'traffic'}{'applicationThroughputStatistics'}{'connectionsOutThroughput'}) {
	    my $app_out=$_->{'traffic'}{'applicationThroughputStatistics'}{'connectionsOutThroughput'}[0]{'outThroughput'};
	    $output_perf=$output_perf."RPA${rpa_id}_appOut=${app_out}B;;;; ";
	}

	if ($_->{'traffic'}{'connectionsCompressionRatio'}) {
	    my $comp_ratio=$_->{'traffic'}{'connectionsCompressionRatio'}[0]{'compressionRatio'};
	    $output_perf=$output_perf."RPA${rpa_id}_compRatio=$comp_ratio;;;; ";
	}
	
    }

    print "RPA status for $cluster : ".$STATUS_STR[$global_status]." ".$output_perf."\n";
    exit $STATUS_EXIT{$STATUS_STR[$global_status]};

}


GetOptions(
    "cluster=s"  => \$cluster,
    "username=s"  => \$username,
    "password=s" => \$password,
    "check_command=s" => \$check_command,
    "group_name=s"    => \$group_name,
    "debug"             => \$debug,
    ) || die("There is invalid option.  Use --help or --man.\n");

# Controle des paramètre

if (not defined $cluster ) { die " Parametre cluster non renseigne"; }
if (not defined $username) { die " Parametre username non renseigne"; }
if (not defined $password) { die " Parametre username non renseigne"; }
if (not defined $check_command) { die "  Parametre check_command non renseigne"; }


switch($check_command) {
    case ("get_system_status") {
	get_system_status();
    }
    case ("get_snapshots_status") {
	if (not defined $group_name) { die "Nom du groupe manquant"; }
	get_snapshots_status();
    }
    
}






