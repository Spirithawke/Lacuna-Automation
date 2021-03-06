#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::PP;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my $body_name;
my $theme_only;
my $debug = 0;
my $test_embassy;

GetOptions(
  "config=s"  => \$config_name,
  "body=s"    => \$body_name,
  "themeonly" => \$theme_only,
  "debug"     => \$debug,
  "test"      => \$test_embassy,
) or die "$0 --config=foo.json --body=Bar\n";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  die "No matching planet for name $body_name\n" unless $body_id;
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

$body_name = $client->body_status($body_id)->{name};
$debug and print "Working on body $body_name\n";

my @foods = qw(algae apple bean beetle bread burger
               cheese chip cider corn fungus lapis
               meal milk pancake pie potato root
               shake soup syrup wheat);

my $buildings = $client->body_buildings($body_id);
$debug and print "Food available: ".$client->body_status($body_id)->{food_stored}."\n";
exit(0) if $client->body_status($body_id)->{food_stored} < 10000;

my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

if ($test_embassy) {
  embassy_fetch();
  exit(0);
}

my $theme = (grep($_->{name} eq "Theme Park",          @buildings))[0];
my $dist  = (grep($_->{name} eq "Distribution Center", @buildings))[0];

if ($dist && $theme && !$theme->{work}) {
  eval { $client->call(distributioncenter => release_reserve => $dist->{id}) } if $dist->{work};
  my $res = $client->call(distributioncenter => get_stored_resources => $dist->{id})->{resources};
  my @sorted = sort { $res->{$b} <=> $res->{$a} } grep { $res->{$_} > 1000 } @foods;
  if (@sorted > 5) {
    my @list = (
      { type => $sorted[4], quantity => 1000 },
      map { { type => $_, quantity => $res->{$_} - 900 } } @sorted[5..$#sorted]
    );
    emit("Holding: ". join(", ", map { "$_->{quantity} $_->{type}" } @list));
    $client->call(distributioncenter => reserve => $dist->{id}, [ @list ]);
    my $max = int($res->{$sorted[4]} / 1000);
    $max = 12 if $max > 12 && @sorted < 10;
    my $view;
    for (2..$max) {
      last unless eval { $view = $client->themepark_operate($theme->{id}); 1; };
    }
    my $embassy = (grep($_->{name} eq "Embassy", @buildings))[0];
    if ($embassy && int(($view->{building}{work}{seconds_remaining} + 3590) / 3600) > 6) {
      embassy_fetch($embassy);
    }
    $client->call(distributioncenter => release_reserve => $dist->{id});
    $client->themepark_operate($theme->{id});
    my $view = $client->call(themepark => view => $theme->{id});
    emit("Confused!  Expected ".scalar(@sorted)." foods, but using $view->{themepark}{food_type_count} foods.")
      if scalar(@sorted) != $view->{themepark}{food_type_count};
    emit("Started theme park ".
         "using $view->{themepark}{food_type_count} foods ".
         # "for ".int($res->{$sorted[4]} / 1000)." hours ".
         "for ".int(($view->{building}{work}{seconds_remaining} + 3590) / 3600)." hours ".
         "at $view->{building}{happiness_hour} happiness/hour.");
  }
}

exit(0) if $theme_only;

my @parks = sort { $b->{level} <=> $a->{level} } grep($_->{name} eq "Park", @buildings);

my $trade = (grep($buildings->{buildings}{$_}{name} eq "Trade Ministry", keys(%{$buildings->{buildings}})))[0];

$debug and print "Park count: ".scalar(@parks)."\n";

for my $park (@parks) {
  next if $park->{work};
  my $before = $client->call(trade => get_stored_resources => $trade);
  my $party = $client->park_party($park->{id});
  my $after = $client->call(trade => get_stored_resources => $trade);
  my @used;
  for my $food (@foods) {
    if ($before->{resources}{$food} > $after->{resources}{$food}) {
      push(@used, ($before->{resources}{$food} - $after->{resources}{$food})." $food");
    }
  }
  emit("Threw level $park->{level} party for $party->{party}{happiness} happiness, using ".join(", ", @used).".");
}

sub embassy_fetch {
  my $embassy = shift;

  $embassy = (grep($_->{name} eq "Embassy", @buildings))[0] unless $embassy;

  my $stash = $client->call(embassy => view_stash => $embassy->{id});
  my %wanted = map { ( $_, (1010 - $stash->{stored}{$_}) ) } grep { $stash->{stored}{$_} < 1010 && $stash->{stored}{$_} + $stash->{stash}{$_} > 1010 } @foods;
  while (List::Util::sum(values(%wanted)) > $stash->{max_exchange_size}) {
    delete($wanted{(sort { $wanted{$b} <=> $wanted{$a} } keys(%wanted))[0]});
  }
  my $amount = List::Util::sum(values(%wanted));
  my %extra = %{$stash->{stored}};
  delete($extra{$_}) for keys(%wanted);
  for my $food (@foods) {
    if ($wanted{$food}) {
      delete($extra{$food});
    } elsif ($extra{$food} > 1010) {
      $extra{$food} -= 1010;
    }
  }
  emit(join("\n", "Extra resources:", map { sprintf("%9d %s", $extra{$_}, $_) } keys(%extra))) if $debug;
  my %giving = $client->select_exchange($stash->{stash}, \%extra, \%wanted);
#   while (($amount = List::Util::sum(values(%wanted)) - List::Util::sum(values(%giving))) > 0) {
#     my @ordered = sort { $stash->{stash}{$a} + $giving{$a} <=> $stash->{stash}{$b} + $giving{$b} } grep { $giving{$_} < $extra{$_} } keys(%extra);
# #    emit("Ordered resources: ". join(", ", @ordered)) if $debug;
#     emit(join("\n", "Ordered resources:", map { sprintf("%9d %s", $stash->{stash}{$_} + $giving{$_}, $_) } @ordered)) if $debug;
#     last unless @ordered;
#     my $top = 1;
#     $top++ while $stash->{stash}{$ordered[$top]} + $giving{$ordered[$top]} == $stash->{stash}{$ordered[0]} + $giving{$ordered[0]};
#     emit("Top: $top, remaining: $amount") if $debug;
#     if ($amount >= $top) {
#       my $step = List::Util::min((map { $extra{$_} - $giving{$_} } @ordered[0..($top-1)]), 
#                                  ($stash->{stash}{$ordered[$top]} + $giving{$ordered[$top]}) - ($stash->{stash}{$ordered[0]} + $giving{$ordered[0]}),
#                                  int($amount / $top));
#       $amount -= $step * $top;
#       $giving{$_} += $step for @ordered[0..($top-1)];
#     } else {
#       $giving{$_}++ for @ordered[0..($amount-1)];
#     }
#     emit(join("\n", "Giving resources:", map { sprintf("%9d %s", $giving{$_}, $_) } keys(%giving))) if $debug;
#   }
  emit(join("\n", "Final stash:", map { sprintf("%9d %s", $stash->{stash}{$_} + $giving{$_}, $_) } keys(%extra))) if $debug;
  emit("Exchanging ". join(", ", map { "$giving{$_} $_" } keys(%giving)). " for ". join(", ", map { "$wanted{$_} $_" } keys(%wanted)));
  emit("Totals ". List::Util::sum(values(%giving)). " for ". List::Util::sum(values(%wanted))) if $debug;
  eval { $client->call(embassy => exchange_with_stash => $embassy->{id}, { %giving }, { %wanted }); } unless $test_embassy;
}

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
